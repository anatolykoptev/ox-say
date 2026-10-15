package daemon

import (
	"bytes"
	"context"
	"encoding/json"
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
// (the filter resamples to 192 kHz internally).
// Mutation: postprocess.go loudnorm, "-af", filter -> "-af", "anull" -> the
// quiet tone stays at about -34 -> RED. Mutation: drop "-ar", strconv.Itoa(rate)
// (and loudnorm's own output-rate self-check) -> 192000 Hz comes out -> RED.
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
// -> RED. Mutation: loudnorm's `secs <= 0` or rate self-check removed -> a
// header-only / wrong-rate output passes for a normalised take -> RED.
func TestNormalizeLoudnessKeepsTheTakeWhenFFmpegFails(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	buf := logBuf(d)
	take := toneBytes(testutil.VoxRate)
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
			useFakeFFmpeg(t, `case "$*" in *print_format*) exit 1;; esac; for a in "$@"; do last=$a; done; /bin/cp `+wrongRate+` "$last"`)
		},
		"ffmpeg writes only a header": func() {
			useFakeFFmpeg(t, `case "$*" in *print_format*) exit 1;; esac; for a in "$@"; do last=$a; done; /bin/cp `+header+` "$last"`)
		},
		"ffmpeg exits 1":  func() { useFakeFFmpeg(t, "echo boom >&2; exit 1") },
		"ffmpeg missing":  func() { t.Setenv("PATH", t.TempDir()) },
		"ffmpeg writes 0": func() { useFakeFFmpeg(t, "exit 0") },
	} {
		setup()
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
	}
	if !strings.Contains(buf.String(), "loudness") || !strings.Contains(buf.String(), "level=WARN") {
		t.Errorf("the failure was not logged: %q", buf.String())
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
func TestNormalizeLoudnessGivesUpOnAHungFFmpeg(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	useFakeFFmpeg(t, "exec /bin/sleep 30")
	prev := loudnormTimeout
	loudnormTimeout = 300 * time.Millisecond
	t.Cleanup(func() { loudnormTimeout = prev })
	take := toneBytes(testutil.QwenRate)
	start := time.Now()
	got, warn := d.normalizeLoudness(context.Background(), take, testTargetLUFS)
	if time.Since(start) > 10*time.Second || !bytes.Equal(got, take) || warn == "" {
		t.Fatalf("hung ffmpeg: %v, kept=%v, warning %q", time.Since(start), bytes.Equal(got, take), warn)
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
// byte-identical, the voxcpm2 take is the engine's own.
// A request that does not ask is not touched at all.
func TestSpeechWithoutLoudnessIsUntouched(t *testing.T) {
	t.Setenv("OXSAY_FAKE_TONE", "1")
	d, _, _ := voxFixture(t, nil)
	for model, rate := range map[string]int{"qwen3-tts": testutil.QwenRate, "voxcpm2": testutil.VoxRate} {
		rec := postSpeech(d, speechBody(model, ``))
		if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), toneBytes(rate)) {
			t.Errorf("%s: %d, %d bytes — not the engine's own take", model, rec.Code, rec.Body.Len())
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
// Mutation: F3 above (normalizeLoudness returns nil on failure) -> RED here.
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

// clickyBytes is a quiet tone with a full-scale click burst every second: its
// peak-to-loudness ratio (about 34 dB) is far beyond what the -1.5 dBTP ceiling
// leaves room for, so single-pass loudnorm lands about 2 LU under the target.
func clickyBytes(rate int) []byte {
	const (
		secs     = 8
		toneAmp  = 0.03
		clickAmp = 0.9
		clickLen = 8
	)
	w := testutil.ToneWAV(rate, secs, toneAmp)
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

// loudnorm is two-pass: on a take whose single pass misses the target by more
// than 1 LU, the result is within 1 LU. The fixture is checked against a
// single-pass run first, so the test cannot pass vacuously.
// Mutation: postprocess.go loudnorm, loudnormFilter(lufs, st) ->
// loudnormFilter(lufs, nil) (single pass) -> RED.
func TestLoudnormIsTwoPass(t *testing.T) {
	take := clickyBytes(testutil.VoxRate)
	in := filepath.Join(t.TempDir(), "in.wav")
	if err := os.WriteFile(in, take, 0o644); err != nil {
		t.Fatal(err)
	}
	single, err := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-i", in, "-af",
		"loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000", "-f", "wav", "pipe:1").Output()
	if err != nil {
		t.Fatal(err)
	}
	if l := integratedLUFS(t, single); math.Abs(l-testTargetLUFS) <= lufsTolerance {
		t.Fatalf("fixture no longer discriminates: single pass reads %.1f LUFS", l)
	}
	got, note, err := loudnorm(context.Background(), t.TempDir(), take, testTargetLUFS)
	if err != nil || note != "" {
		t.Fatalf("%v %q", err, note)
	}
	if l := integratedLUFS(t, got); math.Abs(l-testTargetLUFS) > lufsTolerance {
		t.Errorf("two-pass read %.1f LUFS, want -16 ±1", l)
	}
	// linear mode is one constant gain: the tone between clicks is amplified
	// the same early and late. Dynamic mode rides the gain with the clicks.
	early, late := gainDB(take, got, 0.2, 0.8), gainDB(take, got, 6.2, 6.8)
	if math.Abs(early-late) > gainSlackDB {
		t.Errorf("gain moved from %.2f dB to %.2f dB: not a linear (constant-gain) pass", early, late)
	}
}

// gainSlackDB is how far the gain may drift between two stretches of a take
// that a constant-gain pass amplified.
const gainSlackDB = 0.3

// gainDB is the RMS gain from in to out over [from, to) seconds.
func gainDB(in, out []byte, from, to float64) float64 {
	rate, _ := wavInfo(in)
	rms := func(w []byte) float64 {
		var sum float64
		a, b := int(from*float64(rate)), int(to*float64(rate))
		data := bytes.Index(w, []byte("data")) + 8 // ffmpeg puts a LIST chunk first
		for i := a; i < b; i++ {
			v := float64(int16(uint16(w[data+2*i]) | uint16(w[data+1+2*i])<<8))
			sum += v * v
		}
		return math.Sqrt(sum / float64(b-a))
	}
	return 20 * math.Log10(rms(out)/rms(in))
}

// A failing or unparsable measuring pass degrades to single pass: still
// normalised, and the warning says so. Mutation: drop the `note = warnSinglePass`
// assignment -> RED.
func TestLoudnormFallsBackToSinglePass(t *testing.T) {
	real, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	d, _, _ := voxFixture(t, nil)
	for name, measure := range map[string]string{
		"no JSON in the report": `echo "no report here" >&2; exit 0`,
		"measure exits 1":       `exit 1`,
		"silence reads -inf":    `printf '{"input_i":"-inf","input_tp":"-inf","input_lra":"0.00","input_thresh":"-70.00","target_offset":"0.00"}' >&2; exit 0`,
	} {
		useFakeFFmpeg(t, `case "$*" in *print_format*) `+measure+`;; esac; exec `+real+` "$@"`)
		got, warn := d.normalizeLoudness(context.Background(), toneBytes(testutil.VoxRate), testTargetLUFS)
		if !strings.Contains(warn, "single pass") {
			t.Errorf("%s: warning %q", name, warn)
		}
		if l := integratedLUFS(t, got); math.Abs(l-testTargetLUFS) > lufsTolerance {
			t.Errorf("%s: fell back to %.1f LUFS, want -16 ±1", name, l)
		}
	}
}

// Fixture of the strict file path: a 60 s sine whose level steps up halfway,
// so a dynamic (single pass) loudnorm would ride the gain and a linear
// two-pass one cannot.
const (
	stepSecs      = 60
	stepFreq      = 300.0
	stepQuietDB   = -27.0 // a 9 LU step: inside loudnorm's 11 LU range, so linear mode is allowed
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
// keeps the rate, and is linear (the crest factor is unchanged within
// 0.5 dB); a silent file is an error, never a published unnormalised file.
// Mutation: postprocess.go loudnormFile, loudnormFilter(lufs, st) ->
// loudnormFilter(lufs, nil) (single pass) -> dynamic mode changes the crest
// factor -> RED.
// Mutation: postprocess.go loudnormFile, on a measuring error fall back to a
// single pass -> the silent file succeeds -> RED.
func TestLoudnormFileStrictTwoPass(t *testing.T) {
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
		t.Errorf("crest factor moved from %.2f dB to %.2f dB: not a linear (constant-gain) pass", before, after)
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
// to a single pass (that is only for one take).
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

// loudnormFileReport tells the dynamic fallback from a constant gain, from
// ffmpeg's own normalization_type: a peaky programme cannot reach -16 LUFS
// under a -1.5 dBTP ceiling with one gain; the stepped sine can.
// Mutation: postprocess.go reportedNormType, return "" -> the peaky case reads linear -> RED.
// Mutation: postprocess.go applyLoudnormReport, drop ":print_format=json" -> RED.
func TestLoudnormFileReportsTheDynamicFallback(t *testing.T) {
	dir := t.TempDir()
	peaky := filepath.Join(dir, "peaky.wav")
	if err := os.WriteFile(peaky, clickyBytes(testutil.VoxRate), 0o644); err != nil {
		t.Fatal(err)
	}
	dyn, err := loudnormFileReport(context.Background(), peaky, filepath.Join(dir, "p.wav"), testTargetLUFS)
	if err != nil || !dyn {
		t.Errorf("peaky programme: dynamic=%v err=%v, want dynamic", dyn, err)
	}
	dyn, err = loudnormFileReport(context.Background(), writeStepFile(t, dir), filepath.Join(dir, "s.wav"), testTargetLUFS)
	if err != nil || dyn {
		t.Errorf("stepped sine: dynamic=%v err=%v, want a constant gain", dyn, err)
	}
}
