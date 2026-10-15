package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vscript"
)

// Automatic attempts must stay inside the engine's 32-bit seed range or the
// adapter answers 400 mid-job.
// Mutation: drop the modulo in takeSpec.attempt -> RED.
func TestAttemptSeedStaysInEngineRange(t *testing.T) {
	s := takeSpec{Seed: maxVoxSeed, Cfg: defaultCfgValue, Steps: defaultTimesteps}
	for a := 0; a < maxTakeAttempts; a++ {
		if _, err := voxSeed(map[string]any{fieldSeed: s.attempt(a).Seed}); err != nil {
			t.Errorf("attempt %d: %v", a, err)
		}
	}
	if s.attempt(1).Seed != 0 || s.attempt(2).Cfg != lastAttemptCfg || s.attempt(1).Cfg != defaultCfgValue {
		t.Errorf("%+v %+v", s.attempt(1), s.attempt(2))
	}
}

// The request body is judged by the adapter's own builder: the producer's
// mode, style, seed and sampling arrive as sent.
// Mutation: drop "clone_mode" from renderParams.body -> reference case grows prompt_audio -> RED.
func TestRenderBodyThroughAdapter(t *testing.T) {
	v := &voices.Voice{Name: "nar", RefText: "Привет, как дела у вас сегодня."}
	p := renderParams{Text: "Сохраните это видео.", Voice: "nar", Mode: cloneReference, Seed: 9, Cfg: 1.6, Steps: 12}
	req, err := buildVoxCPM2(p.body(), v, "/v.wav")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := req.body["prompt_audio"]; ok {
		t.Error("reference mode sent a prompt_audio")
	}
	if req.seed != 9 || req.body["guidance_scale"] != 1.6 || req.body["num_inference_steps"] != 12 {
		t.Errorf("sampling lost: %+v", req.body)
	}
	p.Mode = cloneUltimate
	req, err = buildVoxCPM2(p.body(), v, "/v.wav")
	if err != nil || req.body["prompt_audio"] != "/v.wav" || req.body["input"] != p.Text {
		t.Fatalf("ultimate: %v %+v", err, req.body)
	}
	p.Mode, p.Style = cloneReference, "calm"
	req, err = buildVoxCPM2(p.body(), v, "/v.wav")
	if err != nil || req.body["input"] != "(calm)"+p.Text {
		t.Fatalf("style: %v %+v", err, req.body)
	}
}

// Clone mode is the adapter's rule applied to every chunk (D5).
// Mutation: jobCloneMode returns ultimate when ANY chunk is ultimate -> RED.
func TestJobCloneModeFollowsAdapter(t *testing.T) {
	ru := voiceFacts{Name: "nar", RefText: "Привет, как дела у вас сегодня."}
	plain := vscript.Chunk{Spoken: "Сохраните это видео."}
	styled := vscript.Chunk{Spoken: "Сохраните это видео.", Style: "excited"}
	cases := []struct {
		name   string
		f      voiceFacts
		job    string
		chunks []vscript.Chunk
		mode   string
		styles []string
	}{
		{"all plain", ru, "", []vscript.Chunk{plain, plain}, cloneUltimate, []string{"", ""}},
		{"one styled", ru, "", []vscript.Chunk{plain, styled}, cloneReference, []string{"", "excited"}},
		{"job style", ru, "calm", []vscript.Chunk{plain}, cloneReference, []string{"calm"}},
		{"voice default style", voiceFacts{Name: "n", RefText: ru.RefText, Style: "warm"}, "", []vscript.Chunk{plain}, cloneReference, []string{"warm"}},
		{"no transcript", voiceFacts{Name: "n"}, "", []vscript.Chunk{plain}, cloneReference, []string{""}},
		{"other script", ru, "", []vscript.Chunk{{Spoken: "Save this video."}}, cloneReference, []string{""}},
	}
	for _, c := range cases {
		mode, styles, err := jobCloneMode(c.f, c.job, c.chunks)
		if err != nil || mode != c.mode || strings.Join(styles, "|") != strings.Join(c.styles, "|") {
			t.Errorf("%s: %q %q %v", c.name, mode, styles, err)
		}
	}
}

type badWAVPorts struct {
	*fakePorts
	wav []byte
}

func (b *badWAVPorts) Render(ctx context.Context, p renderParams) (*synthOut, error) {
	out, err := b.fakePorts.Render(ctx, p)
	if err == nil {
		out.WAV = b.wav
	}
	return out, err
}

// An engine answer that is not a whole PCM WAV is never stored as a take.
// Mutation: skip pcm.Decode in taker.render -> garbage is stored -> RED.
func TestTakeRefusesBrokenAudio(t *testing.T) {
	good := toneClip(1, 0).Encode()
	cases := map[string][]byte{
		"garbage":   []byte("not a wav at all"),
		"truncated": good[:len(good)/2],
		"empty":     pcm.Clip{Rate: 48000}.Encode(),
	}
	for name, wav := range cases {
		tk := &taker{ports: &badWAVPorts{newFakePorts(t), wav}, dir: t.TempDir(), quiet: noQuiet}
		s := takeSpec{V: takeKeyVersion, Text: "Текст.", Seed: 1, Cfg: 2, Steps: 10}
		if _, _, err := tk.take(context.Background(), s, 0); err == nil {
			t.Errorf("%s: accepted", name)
		}
		if entries, _ := os.ReadDir(tk.dir); len(entries) != 0 {
			t.Errorf("%s: files written: %v", name, entries)
		}
	}
}

// A changed voice file (new SHA) or engine is a cache miss; the same spec hits.
// Mutation: omit VoiceSHA from the key (json:"-") -> the second call is a hit -> RED.
func TestTakeCacheMissesOnVoiceChange(t *testing.T) {
	f := newFakePorts(t)
	tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
	s := takeSpec{V: takeKeyVersion, Engine: "e", Voice: "nar", VoiceSHA: "aa", Mode: cloneReference, Text: "Раз два три.", Seed: 7, Cfg: 2, Steps: 10}
	steps := []struct {
		mut     func(*takeSpec)
		renders int
	}{
		{func(*takeSpec) {}, 1}, {func(*takeSpec) {}, 1},
		{func(s *takeSpec) { s.VoiceSHA = "bb" }, 2},
		{func(s *takeSpec) { s.Engine = "e2" }, 3},
		{func(s *takeSpec) { s.V = takeKeyVersion + 1 }, 4},
	}
	for i, st := range steps {
		st.mut(&s)
		if _, _, err := tk.take(context.Background(), s, 0); err != nil {
			t.Fatal(err)
		}
		if len(f.renders) != st.renders {
			t.Fatalf("step %d: %d renders, want %d", i, len(f.renders), st.renders)
		}
	}
}

type hearFails struct {
	*fakePorts
	err error
}

func (h *hearFails) Hear(context.Context, string) ([]voices.Word, error) { return nil, h.err }

// A failed transcription keeps the WAV and writes no sidecar: the next call
// re-gates without rendering again.
func TestTakeResumesAfterHearFailure(t *testing.T) {
	f := newFakePorts(t)
	s := takeSpec{V: takeKeyVersion, Text: "Раз два три.", Seed: 7, Cfg: 2, Steps: 10}
	bad := &taker{ports: &hearFails{f, errors.New("stt busy")}, dir: t.TempDir(), quiet: noQuiet}
	if _, _, err := bad.take(context.Background(), s, 0); err == nil {
		t.Fatal("hear failure swallowed")
	}
	if _, err := os.Stat(filepath.Join(bad.dir, s.key()+".json")); err == nil {
		t.Fatal("sidecar written without a gate result")
	}
	ok := &taker{ports: f, dir: bad.dir, quiet: noQuiet}
	ref, rendered, err := ok.take(context.Background(), s, 0)
	if err != nil || rendered || len(f.renders) != 1 || !ref.Passed {
		t.Fatalf("%v rendered=%v renders=%d %+v", err, rendered, len(f.renders), ref)
	}
}

// The gate itself: a long inner gap fails with its length, an empty
// transcript fails the WER branch, silence at the edges does not count.
func TestGateTakeDirect(t *testing.T) {
	text := "Сохраните это видео чтобы не забыть."
	words := func(s string) []voices.Word {
		var ws []voices.Word
		for _, w := range strings.Fields(s) {
			ws = append(ws, voices.Word{W: w})
		}
		return ws
	}
	gap := toneClip(2, 2.0)
	if fails, _, _ := gateTake(text, gap, words(text)); len(fails) != 1 || !strings.Contains(fails[0], "silence") {
		t.Errorf("gap: %v", fails)
	}
	edge := pcm.Clip{Rate: 48000, S: append(append(make([]int16, 3*48000), toneClip(2, 0).S...), make([]int16, 3*48000)...)}
	if fails, _, _ := gateTake(text, edge, words(text)); len(fails) != 0 {
		t.Errorf("edge silence failed the take: %v", fails)
	}
	if fails, errs, n := gateTake(text, toneClip(2, 0), nil); len(fails) != 1 || errs != n || n == 0 {
		t.Errorf("empty transcript: %v %d/%d", fails, errs, n)
	}
	// one error in six words is over 10 % but not over gateMinErrors
	if fails, errs, _ := gateTake(text, toneClip(2, 0), words("Сохраните это видео чтобы не забыли")); len(fails) != 0 || errs != 1 {
		t.Errorf("single slip failed: %v errs=%d", fails, errs)
	}
}

// Parakeet's <unk> (a spoken dash) is not a word the take got wrong; a take
// that is wrong still fails.
// Mutation: stop filtering asrUnknown in gateTake -> the dash case fails -> RED.
func TestGateTakeIgnoresASRUnknown(t *testing.T) {
	text := "Первый — ходить пешком двадцать минут без телефона. Второй — записывать мысли сразу."
	heard := []voices.Word{}
	for _, w := range strings.Fields("Первый <unk> ходить пешком двадцать минут без телефона. Второй <unk> записывать мысли сразу.") {
		heard = append(heard, voices.Word{W: w})
	}
	if fails, errs, _ := gateTake(text, toneClip(2, 0), heard); len(fails) != 0 || errs != 0 {
		t.Errorf("<unk> counted: %v errs=%d", fails, errs)
	}
	bad := []voices.Word{{W: "<unk>"}, {W: "<unk>"}, {W: "<unk>"}}
	if fails, _, _ := gateTake(text, toneClip(2, 0), bad); len(fails) != 1 {
		t.Errorf("an all-<unk> transcript passed: %v", fails)
	}
}

func wordsOf(s string) []voices.Word {
	var ws []voices.Word
	for _, w := range strings.Fields(s) {
		ws = append(ws, voices.Word{W: w})
	}
	return ws
}

// The engine is asked to say Chunk.Spoken ("то есть"), so that is what a take
// is judged against; the written "Т.е." would score the right audio as wrong.
// Mutation: vscript.Spoken without expandAbbreviations -> the take fails -> RED.
func TestTakeIsGatedAgainstSpokenText(t *testing.T) {
	chunks, err := vscript.Parse("Начните с одного приёма. Т.е. с самого простого.",
		vscript.Options{TargetChars: 250, MaxChars: 400, MinChars: 80, MaxScriptChars: 40000})
	if err != nil || len(chunks) != 1 {
		t.Fatalf("%v %+v", err, chunks)
	}
	c := chunks[0]
	saidAloud := "начните с одного приёма то есть с самого простого"
	f := newFakePorts(t)
	f.heard[0] = saidAloud
	tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
	spec := takeSpec{V: takeKeyVersion, Mode: cloneReference, Text: c.Spoken, Seed: 1, Cfg: 2, Steps: 10}
	if ref, _, err := tk.take(context.Background(), spec, 0); err != nil || !ref.Passed {
		t.Fatalf("a take that says the Spoken text failed: %v %+v", err, ref)
	}
	if fails, _, _ := gateTake(c.Text, toneClip(2, 0), wordsOf(saidAloud)); len(fails) == 0 {
		t.Fatal("the written text would also pass: the test proves nothing")
	}
}

// A cache hit is re-judged from the stored heard words and WAV under the
// current limits (no render, no transcription), and keeps the plausibility
// warning recorded when the take was made.
// Mutation: return d.Ref from the sidecar on a hit -> second verdict unchanged -> RED.
func TestCachedTakeIsRegatedWithCurrentLimits(t *testing.T) {
	f := newFakePorts(t)
	f.warning = "the take is 30.0 s, longer than its text plausibly needs"
	f.gapAt[0] = 1.0 // under the 1.5 s default, over a stricter limit
	tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
	s := takeSpec{V: takeKeyVersion, Mode: cloneReference, Text: "Раз два три четыре.", Seed: 7, Cfg: 2, Steps: 10}
	first, rendered, err := tk.take(context.Background(), s, 0)
	if err != nil || !rendered || !first.Passed {
		t.Fatalf("%v rendered=%v %+v", err, rendered, first)
	}
	tk.limits = defaultGate
	tk.limits.MaxSilenceSec = 0.5
	second, rendered, err := tk.take(context.Background(), s, 0)
	if err != nil || rendered || len(f.renders) != 1 || f.hears != 1 {
		t.Fatalf("%v rendered=%v renders=%d hears=%d", err, rendered, len(f.renders), f.hears)
	}
	if second.Passed || len(second.Reasons) != 2 || !strings.HasPrefix(second.Reasons[1], noteReason) {
		t.Fatalf("stale verdict or lost warning: %+v", second)
	}
	tk.limits = defaultGate
	if third, _, _ := tk.take(context.Background(), s, 0); !third.Passed {
		t.Fatalf("loosening the limit did not re-pass the cached take: %+v", third)
	}
}
