package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// Loudness targets the tests ask for, and the slack the meter is given.
const (
	testTargetLUFS = -16.0
	lufsTolerance  = 1.0 // LU
)

// toneBytes is a 6 s sine far below the target, so an un-normalised take cannot
// pass for a normalised one.
func toneBytes(rate int) []byte { return testutil.ToneWAV(rate, testutil.ToneSecs, testutil.ToneAmp) }

var lufsRe = regexp.MustCompile(`I:\s+(-?[0-9.]+) LUFS`)

// integratedLUFS measures a WAV with ffmpeg's EBU R128 meter — an oracle
// independent of the loudnorm filter under test. It takes any container ffmpeg
// reads, so an mp3 body works too.
func integratedLUFS(t *testing.T, audio []byte, inputArgs ...string) float64 {
	t.Helper()
	p := filepath.Join(t.TempDir(), "m.bin")
	if err := os.WriteFile(p, audio, 0o644); err != nil {
		t.Fatal(err)
	}
	args := append([]string{"-hide_banner", "-nostats"}, inputArgs...)
	args = append(args, "-i", p, "-af", "ebur128", "-f", "null", "-")
	out, _ := exec.Command("ffmpeg", args...).CombinedOutput()
	m := lufsRe.FindAllStringSubmatch(string(out), -1)
	if len(m) == 0 {
		t.Fatalf("no ebur128 summary: %s", out)
	}
	l, err := strconv.ParseFloat(m[len(m)-1][1], 64)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// useFakeFFmpeg puts an ffmpeg stand-in with the given sh body first (and only)
// on PATH.
func useFakeFFmpeg(t *testing.T, body string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ffmpeg"), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
}

// logBuf makes d log into a buffer.
func logBuf(d *Daemon) *bytes.Buffer {
	var buf bytes.Buffer
	d.log = slog.New(slog.NewTextHandler(&buf, nil))
	return &buf
}

// loudnorm lands within 1 LU of the target AND keeps the engine's sample rate
// (the limiter runs at 4x the rate internally).
// Mutation: loudness.go renderLevel, "-af", filter -> "-af", "anull" -> the
// quiet tone stays at about -34 -> RED. Mutation: drop "-ar", strconv.Itoa(rate)
// (and renderLevel's own output-rate self-check) -> the limiter's rate comes out -> RED.
func TestLoudnormHitsTargetAtTheEngineRate(t *testing.T) {
	for _, rate := range []int{testutil.VoxRate, testutil.QwenRate} {
		got, note, err := loudnorm(context.Background(), t.TempDir(), toneBytes(rate), testTargetLUFS)
		if err != nil {
			t.Fatal(err)
		}
		if note != "" {
			t.Errorf("rate %d: unexpected degrade note %q", rate, note)
		}
		if gotRate, _ := wavInfo(got); gotRate != rate {
			t.Errorf("rate %d, want %d kept", gotRate, rate)
		}
		if l := integratedLUFS(t, got); math.Abs(l-testTargetLUFS) > lufsTolerance {
			t.Errorf("rate %d: integrated loudness %.1f, want %.0f ±%.0f", rate, l, testTargetLUFS, lufsTolerance)
		}
	}
}

// Mutation: validLUFS, `v < minLUFS || v > maxLUFS` -> `false` -> -60 and 0
// pass -> RED. Mutation: drop the math.IsNaN check -> NaN passes -> RED.
// Mutation: loudnessTarget, drop delete(body, fieldLoudness) -> the field
// would reach the engine -> RED.
func TestLoudnessTargetValidates(t *testing.T) {
	for _, bad := range []any{"loud", "-16", true, -60.0, -40.5, -4.9, 0.0, 12.0, math.NaN(), math.Inf(-1), json.Number("-80")} {
		body := map[string]any{"loudness_lufs": bad}
		if v, err := loudnessTarget(body); err == nil {
			t.Errorf("accepted %v -> %v", bad, *v)
		} else if _, ok := err.(*requestError); !ok {
			t.Errorf("%v: %T, want a requestError (HTTP 400)", bad, err)
		}
	}
	for _, edge := range []float64{minLUFS, maxLUFS} {
		if v, err := loudnessTarget(map[string]any{"loudness_lufs": edge}); err != nil || *v != edge {
			t.Errorf("edge %v refused: %v", edge, err)
		}
	}
	b := map[string]any{"loudness_lufs": json.Number("-14"), "input": "x"}
	if v, err := loudnessTarget(b); err != nil || *v != -14 || b["loudness_lufs"] != nil || b["input"] != "x" {
		t.Fatalf("%v %v %v (the field must be popped, never forwarded)", v, err, b)
	}
	for _, none := range []map[string]any{{}, {"loudness_lufs": nil}} {
		if v, err := loudnessTarget(none); v != nil || err != nil {
			t.Errorf("%v: got %v %v, want no normalisation", none, v, err)
		}
		if _, ok := none["loudness_lufs"]; ok {
			t.Errorf("%v: field left in the body", none)
		}
	}
}

// A failing or missing ffmpeg must not lose the take: the original audio
// comes back, with a plain-words warning, and the failure is logged.
// Mutation: postprocess.go normalizeLoudness, the default branch
// `return wav, warnFFmpegFailed` -> `return nil, ...` (the take is dropped)
// -> RED. Mutation: renderLevel's `secs <= 0` or rate self-check removed -> a
// header-only / wrong-rate output passes for a normalised take -> RED.
func TestNormalizeLoudnessKeepsTheTakeWhenFFmpegFails(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	buf := logBuf(d)
	take := toneBytes(testutil.VoxRate)
	real, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	header := filepath.Join(t.TempDir(), "header.wav")
	if err := os.WriteFile(header, testutil.ToneWAV(testutil.VoxRate, 0, 0), 0o644); err != nil {
		t.Fatal(err)
	}
	wrongRate := filepath.Join(t.TempDir(), "wrong-rate.wav")
	if err := os.WriteFile(wrongRate, testutil.ToneWAV(testutil.QwenRate, 1, testutil.ToneAmp), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, setup := range map[string]func(){
		"ffmpeg writes the wrong rate": func() {
			useFakeFFmpeg(t, `case "$*" in *ebur128*) exec `+real+` "$@";; esac; for a in "$@"; do last=$a; done; /bin/cp `+wrongRate+` "$last"`)
		},
		"ffmpeg writes only a header": func() {
			useFakeFFmpeg(t, `case "$*" in *ebur128*) exec `+real+` "$@";; esac; for a in "$@"; do last=$a; done; /bin/cp `+header+` "$last"`)
		},
		"ffmpeg exits 1":  func() { useFakeFFmpeg(t, "echo boom >&2; exit 1") },
		"ffmpeg missing":  func() { t.Setenv("PATH", t.TempDir()) },
		"ffmpeg writes 0": func() { useFakeFFmpeg(t, "exit 0") },
	} {
		setup()
		buf.Reset()
		got, warn := d.normalizeLoudness(context.Background(), take, testTargetLUFS)
		if !bytes.Equal(got, take) {
			t.Errorf("%s: the take was not returned untouched (%d bytes, want %d)", name, len(got), len(take))
		}
		if !strings.Contains(warn, "not normalised") {
			t.Errorf("%s: warning %q does not say so in plain words", name, warn)
		}
		if strings.ContainsAny(warn, "\r\n") {
			t.Errorf("%s: warning %q cannot be a header value", name, warn)
		}
		if !strings.Contains(buf.String(), "loudness") || !strings.Contains(buf.String(), "level=WARN") {
			t.Errorf("%s: the failure was not logged: %q", name, buf.String())
		}
	}
}

func TestNormalizeLoudnessNamesAMissingFFmpeg(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	t.Setenv("PATH", t.TempDir())
	_, warn := d.normalizeLoudness(context.Background(), toneBytes(testutil.QwenRate), testTargetLUFS)
	if !strings.Contains(warn, "ffmpeg is not installed") {
		t.Errorf("warning %q does not name the missing tool", warn)
	}
}

// A hung ffmpeg ends at the deadline and the take is returned, not held.
// Mutation: postprocess.go normalizeLoudness, `case errors.Is(ctx.Err(),
// context.DeadlineExceeded):` -> `case false:` -> the generic "could not
// process" warning -> RED.
func TestNormalizeLoudnessGivesUpOnAHungFFmpeg(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	useFakeFFmpeg(t, "exec /bin/sleep 30")
	prev := loudnormTimeout
	loudnormTimeout = 300 * time.Millisecond
	t.Cleanup(func() { loudnormTimeout = prev })
	take := toneBytes(testutil.QwenRate)
	start := time.Now()
	got, warn := d.normalizeLoudness(context.Background(), take, testTargetLUFS)
	if time.Since(start) > 10*time.Second || !bytes.Equal(got, take) {
		t.Fatalf("hung ffmpeg: %v, kept=%v", time.Since(start), bytes.Equal(got, take))
	}
	if warn != warnFFmpegSlow {
		t.Errorf("warning %q, want the \"took too long\" one (%q)", warn, warnFFmpegSlow)
	}
}

// testPhrase is long enough that the fake's 6 s take trips no runaway guard.
const testPhrase = "Громкость под контролем."

func speechBody(model, extra string) string {
	return `{"model":"` + model + `","input":"` + testPhrase + `"` + extra + `}`
}

// Both engines' takes are normalised over HTTP, each at its own rate, and the
// field never reaches the engine.
// Mutation: http.go handleSpeechBuffered, normalizeTake(.., req.lufs) ->
// (.., nil) -> RED for both. Mutation: handleSpeech, `model == voxcpm2 ||
// lufs != nil` -> `model == voxcpm2` -> the qwen take streams through
// un-normalised -> RED.
func TestSpeechLoudnessOverHTTP(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, logPath := voxFixture(t, nil)
	for _, tc := range []struct {
		model string
		rate  int
	}{{"voxcpm2", testutil.VoxRate}, {"qwen3-tts", testutil.QwenRate}} {
		rec := postSpeech(d, speechBody(tc.model, `,"loudness_lufs":-16,"response_format":"wav"`))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", tc.model, rec.Code, bodyText(rec))
		}
		if rate, _ := wavInfo(rec.Body.Bytes()); rate != tc.rate {
			t.Errorf("%s: rate %d, want %d", tc.model, rate, tc.rate)
		}
		if l := integratedLUFS(t, rec.Body.Bytes()); math.Abs(l-testTargetLUFS) > lufsTolerance {
			t.Errorf("%s: %.1f LUFS, want -16 ±1", tc.model, l)
		}
		if w := rec.Header().Get("X-Ox-Say-Warning"); w != "" {
			t.Errorf("%s: unexpected warning %q", tc.model, w)
		}
	}
	for _, req := range voxLog(t, logPath) {
		if _, ok := req["loudness_lufs"]; ok {
			t.Errorf("loudness_lufs was forwarded to the engine: %v", req)
		}
	}
}

// Asking for nothing changes nothing: the qwen take streams through
// byte-identical, the voxcpm2 take is the engine's own. An explicit
// `"loudness_lufs": null` counts as not asking, and the field is not
// forwarded to the engine as a null.
func TestSpeechWithoutLoudnessIsUntouched(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, _ := voxFixture(t, nil)
	for model, rate := range map[string]int{"qwen3-tts": testutil.QwenRate, "voxcpm2": testutil.VoxRate} {
		for name, extra := range map[string]string{"absent": ``, "null": `,"loudness_lufs":null`} {
			rec := postSpeech(d, speechBody(model, extra))
			if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), toneBytes(rate)) {
				t.Errorf("%s/%s: %d, %d bytes — not the engine's own take", model, name, rec.Code, rec.Body.Len())
			}
			if w := rec.Header().Get("X-Ox-Say-Warning"); w != "" {
				t.Errorf("%s/%s: unexpected warning %q", model, name, w)
			}
		}
	}
}

// Asking for a level does not change qwen's own default format (raw 24 kHz
// s16le pcm), nor voxcpm2's (wav).
// Mutation: http.go handleSpeechBuffered, drop the qwen `format = "pcm"` ->
// the take comes back as wav -> RED.
func TestSpeechLoudnessKeepsTheDefaultFormat(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, _ := voxFixture(t, nil)
	rec := postSpeech(d, speechBody("qwen3-tts", `,"loudness_lufs":-16`))
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "audio/pcm" {
		t.Fatalf("qwen: %d %v", rec.Code, rec.Header())
	}
	if rate, _ := wavInfo(rec.Body.Bytes()); rate != 0 {
		t.Fatal("qwen default answered a WAV, want raw pcm")
	}
	raw := []string{"-f", "s16le", "-ar", strconv.Itoa(testutil.QwenRate), "-ac", "1"}
	if l := integratedLUFS(t, rec.Body.Bytes(), raw...); math.Abs(l-testTargetLUFS) > lufsTolerance {
		t.Errorf("qwen pcm at %.1f LUFS, want -16 ±1", l)
	}
	rec = postSpeech(d, speechBody("voxcpm2", `,"loudness_lufs":-16`))
	if rec.Header().Get("Content-Type") != "audio/wav" {
		t.Errorf("voxcpm2 default Content-Type = %q", rec.Header().Get("Content-Type"))
	}
}

// An mp3 of a normalised qwen take is encoded from the normalised audio.
func TestSpeechLoudnessThenMP3(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, _ := voxFixture(t, nil)
	rec := postSpeech(d, speechBody("qwen3-tts", `,"loudness_lufs":-16,"response_format":"mp3"`))
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "audio/mpeg" {
		t.Fatalf("%d %v", rec.Code, rec.Header())
	}
	if l := integratedLUFS(t, rec.Body.Bytes()); math.Abs(l-testTargetLUFS) > lufsTolerance+0.5 {
		t.Errorf("mp3 at %.1f LUFS, want -16 (mp3 encoder slack)", l)
	}
}

// An out-of-range target is a 400 before any engine is touched.
// Mutation: http.go handleSpeech, loudnessTarget(body) ->
// loudnessTarget(map[string]any{}) -> the request renders and answers 200
// -> RED.
func TestSpeechRefusesAnInsaneLoudnessBeforeRendering(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	for _, v := range []string{`-60`, `0`, `"loud"`, `[]`} {
		rec := postSpeech(d, speechBody("voxcpm2", `,"loudness_lufs":`+v))
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "loudness_lufs") {
			t.Errorf("%s: %d %s", v, rec.Code, bodyText(rec))
		}
	}
	if n := len(voxLog(t, logPath)); n != 0 {
		t.Errorf("%d render(s) happened before validation", n)
	}
}

// ffmpeg failing on the HTTP path answers 200 with the engine's own take and a
// warning header — never a 500 that loses the render.
// Mutation: postprocess.go normalizeLoudness, the default branch
// `return wav, warnFFmpegFailed` -> `return nil, ...` -> RED here.
func TestSpeechLoudnessFFmpegFailureKeepsTheTake(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, _ := voxFixture(t, nil)
	useFakeFFmpeg(t, "exit 1")
	rec := postSpeech(d, speechBody("voxcpm2", `,"loudness_lufs":-16`))
	if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), toneBytes(testutil.VoxRate)) {
		t.Fatalf("%d, %d bytes: want 200 and the engine's own take", rec.Code, rec.Body.Len())
	}
	if w := rec.Header().Get("X-Ox-Say-Warning"); !strings.Contains(w, "not normalised") {
		t.Errorf("X-Ox-Say-Warning = %q", w)
	}
}

// elapsed_s is the whole wall time of the call, normalisation included: a slow
// ffmpeg pass must show in it.
// Mutation: speak.go Speak, move `elapsed := time.Since(start)` back above
// d.normalizeTake -> elapsed_s excludes the pass -> RED.
func TestSpeakElapsedIncludesNormalisation(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, _ := voxFixture(t, nil)
	useFakeFFmpeg(t, "/bin/sleep 1.5; exit 1")
	lufs := testTargetLUFS
	res, err := d.Speak(context.Background(), SpeakInput{Text: testPhrase, Model: "voxcpm2", LoudnessLUFS: &lufs})
	if err != nil {
		t.Fatal(err)
	}
	if res.ElapsedS < 1.4 {
		t.Errorf("elapsed_s = %.2f: the 1.5 s normalisation pass is missing from it", res.ElapsedS)
	}
}

// Speak (the MCP tool / CLI core) honours LoudnessLUFS the same way, validates
// before rendering, and reports an ffmpeg failure as SpeakResult.Warning with
// the file still written.
// Mutation: speak.go Speak, normalizeTake(.., in.LoudnessLUFS) -> (.., nil)
// -> RED. Mutation: drop the validLUFS call -> RED on the range case.
func TestSpeakLoudness(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, logPath := voxFixture(t, nil)
	lufs := testTargetLUFS
	res, err := d.Speak(context.Background(), SpeakInput{Text: testPhrase, Model: "voxcpm2", LoudnessLUFS: &lufs})
	if err != nil {
		t.Fatal(err)
	}
	wav, err := os.ReadFile(res.Path)
	if err != nil {
		t.Fatal(err)
	}
	if rate, _ := wavInfo(wav); rate != testutil.VoxRate {
		t.Errorf("rate %d, want %d", rate, testutil.VoxRate)
	}
	if l := integratedLUFS(t, wav); math.Abs(l-testTargetLUFS) > lufsTolerance {
		t.Errorf("%.1f LUFS, want -16 ±1", l)
	}
	if res.Warning != "" {
		t.Errorf("unexpected warning %q", res.Warning)
	}

	before := len(voxLog(t, logPath))
	insane := -60.0
	if _, err := d.Speak(context.Background(), SpeakInput{Text: "x", Model: "voxcpm2", LoudnessLUFS: &insane}); err == nil {
		t.Error("Speak accepted -60 LUFS")
	}
	if n := len(voxLog(t, logPath)); n != before {
		t.Errorf("Speak rendered before validating loudness (%d -> %d)", before, n)
	}

	useFakeFFmpeg(t, "exit 1")
	res, err = d.Speak(context.Background(), SpeakInput{Text: "Ещё раз. " + testPhrase, Model: "voxcpm2", LoudnessLUFS: &lufs})
	if err != nil {
		t.Fatalf("ffmpeg failure lost the take: %v", err)
	}
	if !strings.Contains(res.Warning, "not normalised") {
		t.Errorf("SpeakResult.Warning = %q", res.Warning)
	}
	if got, err := os.ReadFile(res.Path); err != nil || !bytes.Equal(got, toneBytes(testutil.VoxRate)) {
		t.Errorf("the un-normalised take was not written: %v", err)
	}
}

// peakyBytes is secs seconds of a quiet tone with a full-scale click burst every
// second: its true peak sits far above its loudness (about 24 dB), so a constant
// gain to a broadcast level would put the peaks over the ceiling and the
// limiter has to work.
func peakyBytes(rate, secs int) []byte {
	const (
		toneAmp  = 0.1
		clickAmp = 0.9
		clickLen = 40
	)
	w := testutil.ToneWAV(rate, float64(secs), toneAmp)
	for s := 0; s < secs; s++ {
		for i := 0; i < clickLen; i++ {
			v := int16(math.Round(clickAmp * math.MaxInt16))
			if i%2 == 1 {
				v = -v
			}
			off := 44 + 2*(s*rate+i)
			w[off], w[off+1] = byte(uint16(v)), byte(uint16(v)>>8)
		}
	}
	return w
}

// clicksOnlyBytes is nothing but peaks: the ceiling leaves it far under any
// sensible target, so the result must say it missed.
func clicksOnlyBytes(rate, secs int) []byte {
	const (
		silentAmp = 0
		clickAmp  = 0.9
		clickLen  = 8
	)
	w := testutil.ToneWAV(rate, float64(secs), silentAmp)
	for s := 0; s < secs; s++ {
		for i := 0; i < clickLen; i++ {
			v := int16(math.Round(clickAmp * math.MaxInt16))
			if i%2 == 1 {
				v = -v
			}
			off := 44 + 2*(s*rate+i)
			w[off], w[off+1] = byte(uint16(v)), byte(uint16(v)>>8)
		}
	}
	return w
}

// Tolerances of the meter checks: the loudness target (LU) and the true-peak
// ceiling (dB; the oversampled limiter and the 16-bit rounding may overshoot
// it by a few hundredths).
const (
	levelToleranceLU = 0.5
	truePeakSlackDB  = 0.1
)

var truePeakRe = regexp.MustCompile(`True peak:\s+Peak:\s+(-?[0-9.]+) dBFS`)

// meterOf reads integrated loudness and true peak with ffmpeg's EBU R128
// meter - an oracle independent of the code under test. inputArgs go before -i.
func meterOf(t *testing.T, audio []byte, inputArgs ...string) (lufs, truePeak float64) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "m.wav")
	if err := os.WriteFile(p, audio, 0o644); err != nil {
		t.Fatal(err)
	}
	args := append([]string{"-hide_banner", "-nostats"}, inputArgs...)
	args = append(args, "-i", p, "-af", "ebur128=peak=true", "-f", "null", "-")
	out, _ := exec.Command("ffmpeg", args...).CombinedOutput()
	i, tp := lufsRe.FindAllStringSubmatch(string(out), -1), truePeakRe.FindAllStringSubmatch(string(out), -1)
	if len(i) == 0 || len(tp) == 0 {
		t.Fatalf("no ebur128 summary: %s", out)
	}
	lufs, _ = strconv.ParseFloat(i[len(i)-1][1], 64)
	truePeak, _ = strconv.ParseFloat(tp[len(tp)-1][1], 64)
	return lufs, truePeak
}

// A peaky take lands within 0.5 LU of -14 and of -16 AND holds the -1.5 dBTP
// ceiling, at both engines' rates, 8 s and 2 s long (issues #153, #162). The
// fixture is checked first: one constant gain to the target would put its
// peaks over the ceiling, so the limiter has to work and the test cannot pass
// vacuously. ffmpeg's loudnorm landed the 2 s take 10 LU under the target.
// Mutation: loudness.go levelTo, `limit := in.tpDB+gain > loudnessCeilingDB`
// -> `limit := false` -> the peaks stay over the ceiling -> RED.
// Mutation: loudness.go levelFilter, `f := fmt.Sprintf("volume=%.4fdB", gainDB)`
// -> `f := "volume=0dB"` -> the take keeps its level -> RED.
// Mutation: loudness.go, loudnessRefinements = 4 -> 0 -> the -14 case lands
// 1.3 LU under (the limiter costs loudness) -> RED.
func TestLoudnormHoldsTheCeilingAndHitsTheTargetOnPeakyTakes(t *testing.T) {
	for _, rate := range []int{testutil.VoxRate, testutil.QwenRate} {
		for _, secs := range []int{8, 2} {
			take := peakyBytes(rate, secs)
			inI, inTP := meterOf(t, take)
			for _, target := range []float64{-14, -16} {
				if inTP+(target-inI) <= loudnessCeilingDB {
					t.Fatalf("fixture no longer discriminates: %.1f LUFS / %.1f dBTP needs no limiter for %.0f", inI, inTP, target)
				}
				got, _, err := loudnorm(context.Background(), t.TempDir(), take, target)
				if err != nil {
					t.Fatal(err)
				}
				l, tp := meterOf(t, got)
				name := fmt.Sprintf("%d Hz, %d s, target %.0f", rate, secs, target)
				if math.Abs(l-target) > levelToleranceLU {
					t.Errorf("%s: integrated %.2f LUFS, want within %.1f LU", name, l, levelToleranceLU)
				}
				if tp > loudnessCeilingDB+truePeakSlackDB {
					t.Errorf("%s: true peak %.2f dBTP is over the %.1f ceiling", name, tp, loudnessCeilingDB)
				}
				if gotRate, gotSecs := wavInfo(got); gotRate != rate || math.Abs(gotSecs-float64(secs)) > lengthSlackSec {
					t.Errorf("%s: %d Hz / %.2f s came back", name, gotRate, gotSecs)
				}
			}
		}
	}
}

// lengthSlackSec is how far a levelled take's length may drift (the limiter's
// look-ahead is compensated, so it should not at all: 1 ms is 48 samples at
// 48 kHz, a tenth of the 5 ms look-ahead that an uncompensated limiter loses).
const lengthSlackSec = 0.001

// onsetSlackSamples is how far the first click of a levelled take may move.
const onsetSlackSamples = 4

// A clip shorter than one EBU R128 gating block has no loudness to read; it is
// measured on a looped copy so it still reaches the target. The oracle loops
// the result the same way.
// Mutation: loudness.go measureFilter, `if secs >= gatingBlockSec` -> `if true`
// -> the 0.3 s clip reads as silence and the take is refused -> RED.
func TestLoudnormLevelsAClipShorterThanOneGatingBlock(t *testing.T) {
	const (
		clipSecs = 0.3
		loops    = 12
	)
	clip := testutil.ToneWAV(testutil.VoxRate, clipSecs, testutil.ToneAmp)
	if l, _ := meterOf(t, clip); l > absoluteGateLUFS {
		t.Fatalf("fixture no longer discriminates: the clip reads %.1f LUFS without looping", l)
	}
	got, _, err := loudnorm(context.Background(), t.TempDir(), clip, testTargetLUFS)
	if err != nil {
		t.Fatalf("a short clip was refused: %v", err)
	}
	if l, _ := meterOf(t, got, "-stream_loop", strconv.Itoa(loops)); math.Abs(l-testTargetLUFS) > levelToleranceLU {
		t.Errorf("looped result reads %.2f LUFS, want -16 within %.1f", l, levelToleranceLU)
	}
	if _, secs := wavInfo(got); math.Abs(secs-clipSecs) > lengthSlackSec {
		t.Errorf("length %.3f s, want %.1f s", secs, clipSecs)
	}
}

// A take the limiter had to pull down hard says so in plain words; a gentle
// one carries no note; a take too peaky to reach the target says it missed.
// Mutation: loudness.go levelOutcome.note, return "" always -> RED.
// Mutation: loudness.go levelOutcome.note, swap the order of the two cases ->
// the miss reads as "pulled down" -> RED.
func TestLoudnessNoteNamesTheLimiter(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	_, warn := d.normalizeLoudness(context.Background(), peakyBytes(testutil.VoxRate, 8), -14)
	if !strings.Contains(warn, "peak limiter") || !strings.Contains(warn, "dB") || strings.ContainsAny(warn, "\r\n") {
		t.Errorf("hard limiting: warning %q does not say so in plain words", warn)
	}
	if _, warn := d.normalizeLoudness(context.Background(), toneBytes(testutil.VoxRate), testTargetLUFS); warn != "" {
		t.Errorf("a plain take carries the warning %q", warn)
	}
	_, warn = d.normalizeLoudness(context.Background(), clicksOnlyBytes(testutil.VoxRate, 8), -10)
	if !strings.Contains(warn, "under the target") {
		t.Errorf("a missed target: warning %q does not say so", warn)
	}
}

// A silent take has no loudness to set: the take comes back untouched with a
// warning that names the reason, and the strict path refuses it.
// Mutation: loudness.go measureLevel, drop the `lvl.lufs <= absoluteGateLUFS`
// check -> the silence is "levelled" by +54 dB and reported as normalised -> RED.
func TestLoudnormRefusesSilence(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	silent := testutil.SilentWAV(2)
	got, warn := d.normalizeLoudness(context.Background(), silent, testTargetLUFS)
	if !bytes.Equal(got, silent) || !strings.Contains(warn, "silent or too short") {
		t.Errorf("silence: kept=%v, warning %q", bytes.Equal(got, silent), warn)
	}
	if _, _, err := loudnorm(context.Background(), t.TempDir(), silent, testTargetLUFS); !errors.Is(err, errUnmeasurable) {
		t.Errorf("silence: %v, want errUnmeasurable", err)
	}
}

// Fixture of the strict file path: a 60 s sine whose level steps up halfway.
// One constant gain keeps its crest factor; anything that rides the gain with
// the level (a compressor, a dynamic normaliser) changes it.
const (
	stepSecs      = 60
	stepFreq      = 300.0
	stepQuietDB   = -27.0 // a 9 LU step, small enough that no peak needs the limiter
	stepLoudDB    = -18.0
	crestSlackDB  = 0.5
	silentFileSec = 5
)

func writeStepFile(t *testing.T, dir string) string {
	t.Helper()
	const rate = testutil.VoxRate
	s := make([]int16, stepSecs*rate)
	for i := range s {
		amp := math.Pow(10, stepQuietDB/20)
		if i >= len(s)/2 {
			amp = math.Pow(10, stepLoudDB/20)
		}
		s[i] = int16(amp * math.MaxInt16 * math.Sin(2*math.Pi*stepFreq*float64(i)/rate))
	}
	p := filepath.Join(dir, "in.wav")
	if err := os.WriteFile(p, pcm.Clip{Rate: rate, S: s}.Encode(), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

var astatsRe = regexp.MustCompile(`(Peak level dB|RMS level dB): (-?[0-9.]+)`)

// crestDB is peak minus RMS level over the whole file, read by ffmpeg's
// astats: a constant gain leaves it unchanged, a dynamic one does not.
func crestDB(t *testing.T, path string) float64 {
	t.Helper()
	out, _ := exec.Command("ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "astats", "-f", "null", "-").CombinedOutput()
	txt := string(out)
	if i := strings.LastIndex(txt, "Overall"); i >= 0 {
		txt = txt[i:]
	}
	v := map[string]float64{}
	for _, m := range astatsRe.FindAllStringSubmatch(txt, -1) {
		f, _ := strconv.ParseFloat(m[2], 64)
		v[m[1]] = f
	}
	if len(v) != 2 {
		t.Fatalf("no astats Overall block: %s", out)
	}
	return v["Peak level dB"] - v["RMS level dB"]
}

func fileLUFS(t *testing.T, path string) float64 {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return integratedLUFS(t, raw)
}

// The strict file path: lands within 1 LU on a 60 s file with a level step,
// keeps the rate, and is one constant gain (the crest factor is unchanged
// within 0.5 dB, nothing needed the limiter); a silent file is an error, never a published unnormalised file.
// Mutation: loudness.go levelTo, drop the gain (levelFilter's volume=%.4fdB ->
// volume=0dB) -> the file keeps its level -> RED.
// Mutation: loudness.go levelTo, on errUnmeasurable carry on with gain 0 and
// return nil -> the silent file succeeds -> RED.
func TestLoudnormFileStrictConstantGain(t *testing.T) {
	dir := t.TempDir()
	in, out := writeStepFile(t, dir), filepath.Join(dir, "out.wav")
	if err := loudnormFile(context.Background(), in, out, testTargetLUFS); err != nil {
		t.Fatal(err)
	}
	if l := fileLUFS(t, out); math.Abs(l-testTargetLUFS) > lufsTolerance {
		t.Errorf("integrated %.2f LUFS, want -16 ±1", l)
	}
	if rate, _ := wavInfoFile(out); rate != testutil.VoxRate {
		t.Errorf("rate %d, want %d", rate, testutil.VoxRate)
	}
	if before, after := crestDB(t, in), crestDB(t, out); math.Abs(before-after) > crestSlackDB {
		t.Errorf("crest factor moved from %.2f dB to %.2f dB: not one constant gain", before, after)
	}

	silent := filepath.Join(dir, "silent.wav")
	if err := os.WriteFile(silent, pcm.Silence(testutil.VoxRate, silentFileSec).Encode(), 0o644); err != nil {
		t.Fatal(err)
	}
	out2 := filepath.Join(dir, "out2.wav")
	if err := loudnormFile(context.Background(), silent, out2, testTargetLUFS); err == nil {
		t.Error("a silent file was reported as normalised")
	}
	if _, err := os.Stat(out2); !os.IsNotExist(err) {
		t.Errorf("a silent file left an output behind: %v", err)
	}
}

// Whatever fails, the output path is left empty: ffmpeg dying half way through
// the applying pass leaves no partial file that could pass for the result.
// Mutation: postprocess.go loudnormFile, drop the os.Remove(out) on error -> RED.
func TestLoudnormFileLeavesNoPartialOutput(t *testing.T) {
	real, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	useFakeFFmpeg(t, `case "$*" in *"-f null"*) exec `+real+` "$@";; esac
for a; do last=$a; done
echo junk > "$last"
exit 1`)
	dir := t.TempDir()
	in, out := writeStepFile(t, dir), filepath.Join(dir, "out.wav")
	if err := loudnormFile(context.Background(), in, out, testTargetLUFS); err == nil {
		t.Fatal("a failing apply pass reported success")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Errorf("partial output left behind: %v", err)
	}
}

// A measuring failure on the assembled file is an error: nothing falls back
// to an unmeasured gain.
func TestLoudnormFileMeasureFailureIsAnError(t *testing.T) {
	real, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	for name, measure := range map[string]string{
		"no JSON in the report": `echo "no report here" >&2; exit 0`,
		"measure exits 1":       `exit 1`,
	} {
		useFakeFFmpeg(t, `case "$*" in *"-f null"*) `+measure+`;; esac; exec `+real+` "$@"`)
		dir := t.TempDir()
		in, out := writeStepFile(t, dir), filepath.Join(dir, "out.wav")
		if err := loudnormFile(context.Background(), in, out, testTargetLUFS); err == nil {
			t.Errorf("%s: fell back instead of failing", name)
		}
		if _, err := os.Stat(out); !os.IsNotExist(err) {
			t.Errorf("%s: output exists", name)
		}
	}
}

// loudnormFile refuses what is not a PCM WAV before it starts ffmpeg.
func TestLoudnormFileRefusesNonWAV(t *testing.T) {
	dir := t.TempDir()
	in := filepath.Join(dir, "x.wav")
	if err := os.WriteFile(in, []byte("nope"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := loudnormFile(context.Background(), in, filepath.Join(dir, "o.wav"), testTargetLUFS); err == nil {
		t.Fatal("a non-WAV was accepted")
	}
}

// Both passes are bounded in proportion to the audio.
// Mutation: postprocess.go loudnormFileTimeout, drop the passes factor -> RED.
func TestLoudnormFileTimeoutScalesWithDuration(t *testing.T) {
	short, long := loudnormFileTimeout(10), loudnormFileTimeout(3600)
	if short < loudnormPasses*loudnormFileBase {
		t.Errorf("a 10 s file gets only %v", short)
	}
	if long <= short || long < time.Duration(3600*loudnormFilePerSec*float64(time.Second)) {
		t.Errorf("an hour of audio gets %v (10 s: %v)", long, short)
	}
}

// loudnormFileReport says when the limiter had to work hard: a peaky programme
// needs it, the stepped sine (one constant gain) does not.
// Mutation: loudness.go levelOutcome.limited, return false always -> RED.
// Mutation: loudness.go, limitNoteDB = 6.0 -> 100 -> the peaky case reads
// as a light touch -> RED.
func TestLoudnormFileReportsLimiting(t *testing.T) {
	dir := t.TempDir()
	peaky := filepath.Join(dir, "peaky.wav")
	if err := os.WriteFile(peaky, peakyBytes(testutil.VoxRate, 8), 0o644); err != nil {
		t.Fatal(err)
	}
	limited, err := loudnormFileReport(context.Background(), peaky, filepath.Join(dir, "p.wav"), -14)
	if err != nil || !limited {
		t.Errorf("peaky programme: limited=%v err=%v, want limited", limited, err)
	}
	limited, err = loudnormFileReport(context.Background(), writeStepFile(t, dir), filepath.Join(dir, "s.wav"), testTargetLUFS)
	if err != nil || limited {
		t.Errorf("stepped sine: limited=%v err=%v, want a constant gain", limited, err)
	}
}

// loudTargetLUFS is a loud target at which modulatedBytes needs the limiter.
const loudTargetLUFS = -10.0

// modulatedBytes is secs seconds of four unrelated sines under a 3 Hz
// amplitude swell: a speech-like crest factor of about 12 dB at amplitude amp.
func modulatedBytes(rate, secs int, amp float64) []byte {
	s := make([]int16, rate*secs)
	for i := range s {
		t := float64(i) / float64(rate)
		v := math.Sin(2*math.Pi*180*t) + 0.7*math.Sin(2*math.Pi*440*t+1) + 0.5*math.Sin(2*math.Pi*1130*t+2) + 0.4*math.Sin(2*math.Pi*2600*t+3)
		v *= 0.55 + 0.45*math.Sin(2*math.Pi*3*t)
		s[i] = int16(amp * v * math.MaxInt16)
	}
	return pcm.Clip{Rate: rate, S: s}.Encode()
}

// onsetOf is the index of the first sample louder than a tenth of the take's
// loudest, in a 16-bit mono WAV.
func onsetOf(wav []byte) int {
	data := bytes.Index(wav, []byte("data")) + 8
	n := (len(wav) - data) / 2
	at := func(i int) int {
		v := int(int16(uint16(wav[data+2*i]) | uint16(wav[data+1+2*i])<<8))
		if v < 0 {
			return -v
		}
		return v
	}
	peak := 0
	for i := 0; i < n; i++ {
		peak = max(peak, at(i))
	}
	for i := 0; i < n; i++ {
		if at(i) > peak/10 {
			return i
		}
	}
	return -1
}

// The limiter must only move peaks: its auto-level (which raises the output so
// the ceiling reads 0 dBFS) is off, and its look-ahead delay is compensated
// (else the audio shifts by the 5 ms attack and the tail is cut). The fixture's
// first click sits at sample 0 and its peaks need the limiter.
// Mutation: loudness.go levelFilter, drop ":level=false" -> the output is
// lifted until its peak reads 0 dBFS -> RED.
// Mutation: loudness.go levelFilter, drop ":latency=true" -> the click moves by
// 240 samples and the take is 5 ms short -> RED.
func TestLimiterOnlyMovesThePeaks(t *testing.T) {
	// A loud take whose limited peaks land on the ceiling: with auto-level on,
	// the limiter lifts them to 0 dBFS (this fixture reads 0.00 then).
	loud := modulatedBytes(testutil.VoxRate, 6, 0.2)
	got, _, err := loudnorm(context.Background(), t.TempDir(), loud, loudTargetLUFS)
	if err != nil {
		t.Fatal(err)
	}
	if _, tp := meterOf(t, got); tp > loudnessCeilingDB+truePeakSlackDB/2 {
		t.Errorf("true peak %.2f dBTP, ceiling %.1f: the limiter lifted the output", tp, loudnessCeilingDB)
	}
	take := peakyBytes(testutil.VoxRate, 8)
	got, _, err = loudnorm(context.Background(), t.TempDir(), take, -14)
	if err != nil {
		t.Fatal(err)
	}
	if in, out := onsetOf(take), onsetOf(got); out < 0 || out-in > onsetSlackSamples || in-out > onsetSlackSamples {
		t.Errorf("first click at sample %d, was %d: the audio shifted", out, in)
	}
	if _, secs := wavInfo(got); math.Abs(secs-8) > lengthSlackSec {
		t.Errorf("length %.4f s, want 8", secs)
	}
}

// A meter that prints no true peak must not pass for a measurement: the output
// could clip silently. The per-channel keys count; NaN readings are ignored.
// Mutation: loudness.go scanLevel, `sawLUFS && sawTP` -> `sawLUFS` -> RED.
func TestScanLevelNeedsTheTruePeak(t *testing.T) {
	if _, ok := scanLevel(strings.NewReader("lavfi.r128.I=-20.0\n")); ok {
		t.Error("a reading without a true peak was accepted")
	}
	lvl, ok := scanLevel(strings.NewReader("lavfi.r128.I=nan\nlavfi.r128.I=-20.5\nlavfi.r128.true_peaks_ch0=0.5\nlavfi.r128.true_peaks_ch1=0.8\n"))
	if !ok || lvl.lufs != -20.5 || math.Abs(lvl.tpDB-20*math.Log10(0.8)) > 1e-9 {
		t.Errorf("per-channel peaks: %+v ok=%v, want -20.5 LUFS and the louder channel", lvl, ok)
	}
	if _, ok := scanLevel(strings.NewReader("lavfi.r128.I=nan\nlavfi.r128.true_peak=0.5\n")); ok {
		t.Error("a NaN loudness was accepted")
	}
}

// A hiss-only take would need far more than maxGainDB: the soft path keeps it
// with a plain warning, the strict path refuses it and leaves no output.
// Mutation: loudness.go levelTo, `lufs-in.lufs > maxGainDB` -> `false` -> the
// hiss is raised 47 dB and passes for normalised -> RED.
func TestLoudnormRefusesToBoostHiss(t *testing.T) {
	const hissAmp = 0.001
	hiss := testutil.ToneWAV(testutil.VoxRate, testutil.ToneSecs, hissAmp)
	if l, _ := meterOf(t, hiss); l < absoluteGateLUFS || testTargetLUFS-l <= maxGainDB {
		t.Fatalf("fixture no longer discriminates: reads %.1f LUFS", l)
	}
	d, _, _ := voxFixture(t, nil)
	got, warn := d.normalizeLoudness(context.Background(), hiss, testTargetLUFS)
	if !bytes.Equal(got, hiss) || warn != warnTooQuiet {
		t.Errorf("soft path: kept=%v, warning %q", bytes.Equal(got, hiss), warn)
	}
	dir := t.TempDir()
	in, out := filepath.Join(dir, "hiss.wav"), filepath.Join(dir, "out.wav")
	if err := os.WriteFile(in, hiss, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := loudnormFile(context.Background(), in, out, testTargetLUFS); !errors.Is(err, errTooQuiet) || !strings.Contains(err.Error(), "too quiet") {
		t.Errorf("strict path: %v, want errTooQuiet in plain words", err)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Errorf("the strict path left an output: %v", err)
	}
}
