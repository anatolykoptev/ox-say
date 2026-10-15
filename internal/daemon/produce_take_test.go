package daemon

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// fakePorts implements producePorts for producer tests: it renders a tone
// of secs per request and "hears" the request's text (or an override per
// render index). Shared by F1-3, F1-4 and F1-5 tests.
type fakePorts struct {
	mu          sync.Mutex
	home        string
	secs        float64
	gapAt       map[int]float64 // render index -> insert a silent gap of this many seconds mid-take
	heard       map[int]string  // render index -> transcript override
	warning     string
	renders     []renderParams
	inFlight    int
	maxInFlight int
	block       chan struct{} // non-nil: Render waits for it (or ctx)
	started     chan struct{} // non-nil: Render signals each start
	hears       int
	quietWait   time.Duration
	onBattery   bool
	bg          []bool
	voice       voiceFacts
	voiceErr    error
	unavailable string
	engineID    string
	normErr     error
	normCalls   int
	normHook    func() // non-nil: Normalize calls it first
	normNoop    bool   // Normalize reports success and writes nothing
	normOut     []byte // non-nil: Normalize writes these bytes instead of its input
}

func newFakePorts(t *testing.T) *fakePorts {
	return &fakePorts{home: t.TempDir(), secs: 2, gapAt: map[int]float64{}, heard: map[int]string{},
		voice: voiceFacts{Name: "nar", RefText: "Привет, как дела у вас сегодня.", SHA: "aa"}, engineID: "eng1"}
}

func toneClip(secs, gap float64) pcm.Clip {
	half := make([]int16, int(secs/2*48000))
	for i := range half {
		half[i] = int16(8000 * math.Sin(2*math.Pi*300*float64(i)/48000))
	}
	s := append(append(append([]int16{}, half...), make([]int16, int(gap*48000))...), half...)
	return pcm.Clip{Rate: 48000, S: s}
}

func (f *fakePorts) Render(ctx context.Context, p renderParams) (*synthOut, error) {
	f.mu.Lock()
	idx := len(f.renders)
	f.renders = append(f.renders, p)
	f.inFlight++
	f.maxInFlight = max(f.maxInFlight, f.inFlight)
	block, started, gap := f.block, f.started, f.gapAt[idx]
	f.mu.Unlock()
	defer func() { f.mu.Lock(); f.inFlight--; f.mu.Unlock() }()
	if started != nil {
		started <- struct{}{}
	}
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return &synthOut{WAV: toneClip(f.secs, gap).Encode(), Model: config.TTSModelVoxCPM2, Warning: f.warning}, nil
}

func (f *fakePorts) Hear(_ context.Context, _ string) ([]voices.Word, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hears++
	idx := len(f.renders) - 1
	text := f.renders[idx].Text
	if o, ok := f.heard[idx]; ok {
		text = o
	}
	fs := strings.Fields(text)
	ws := make([]voices.Word, len(fs))
	for i, w := range fs {
		s := f.secs * float64(i) / float64(len(fs))
		ws[i] = voices.Word{W: w, S: s, E: s + f.secs/float64(len(fs))}
	}
	return ws, nil
}

func (f *fakePorts) Voice(string) (voiceFacts, error) { return f.voice, f.voiceErr }
func (f *fakePorts) DefaultVoice(string) string       { return "nar" }
func (f *fakePorts) Unavailable() string              { return f.unavailable }
func (f *fakePorts) EngineID() (string, error)        { return f.engineID, nil }
func (f *fakePorts) Normalize(_ context.Context, in, out string, _, _ float64) error {
	f.mu.Lock()
	f.normCalls++
	err, hook, noop := f.normErr, f.normHook, f.normNoop
	f.mu.Unlock()
	if hook != nil {
		hook()
	}
	if err != nil || noop {
		return err
	}
	raw, rerr := os.ReadFile(in)
	if rerr != nil {
		return rerr
	}
	if f.normOut != nil {
		raw = f.normOut
	}
	return os.WriteFile(out, raw, 0o600)
}
func (f *fakePorts) Quiet(ctx context.Context, onWait func()) error {
	if f.quietWait > 0 {
		onWait()
		select {
		case <-time.After(f.quietWait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}
func (f *fakePorts) Power(context.Context) (bool, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.onBattery, false
}
func (f *fakePorts) Background(on bool) { f.mu.Lock(); f.bg = append(f.bg, on); f.mu.Unlock() }
func (f *fakePorts) Home() string       { return f.home }
func (f *fakePorts) OutputRoot() string { return filepath.Join(f.home, "Movies", "ox-say") }

func noQuiet(context.Context) error { return nil }

// Every input that changes audio is in the key; one row per field.
// Mutation: tag Seed `json:"-"` in takeSpec -> RED.
func TestTakeKeyCoversInputs(t *testing.T) {
	base := takeSpec{V: takeKeyVersion, Engine: "e", Voice: "nar", VoiceSHA: "aa", RefText: "r", Mode: cloneReference,
		Style: "calm", Text: "Текст.", Seed: 1, Cfg: 2, Steps: 10}
	muts := []func(*takeSpec){
		func(s *takeSpec) { s.V = 99 }, func(s *takeSpec) { s.Engine = "e2" }, func(s *takeSpec) { s.Voice = "x" },
		func(s *takeSpec) { s.VoiceSHA = "bb" }, func(s *takeSpec) { s.RefText = "x" }, func(s *takeSpec) { s.Mode = cloneUltimate },
		func(s *takeSpec) { s.Style = "x" }, func(s *takeSpec) { s.Text = "x" }, func(s *takeSpec) { s.Seed = 2 },
		func(s *takeSpec) { s.Cfg = 1.6 }, func(s *takeSpec) { s.Steps = 16 },
	}
	for i, m := range muts {
		s := base
		m(&s)
		if s.key() == base.key() {
			t.Errorf("mutation %d does not change the key", i)
		}
	}
	if s := base.attempt(1); s.basis() != base.basis() || s.key() == base.key() {
		t.Error("basis must ignore seed/cfg; key must not")
	}
}

// Gates: silence and WER fail; the plausibility warning is a recorded
// reason, not a failure (#143.6).
// Mutation: append the warning to fails in take -> the warning case fails -> RED.
// Mutation: drop the WER branch in gateTake -> the wrong-words case passes -> RED.
func TestTakeGates(t *testing.T) {
	f := newFakePorts(t)
	tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
	spec := takeSpec{V: takeKeyVersion, Engine: "e", Voice: "nar", Mode: cloneReference, Seed: 1, Cfg: 2, Steps: 10}
	text := "Сохраните это видео, чтобы не забыть."
	cases := []struct {
		name    string
		setup   func()
		passed  bool
		reasons int
	}{
		{"clean", func() {}, true, 0},
		{"warning only", func() { f.warning = "the take is 30.0 s, longer than its text plausibly needs" }, true, 1},
		{"inner silence", func() { f.warning = ""; f.gapAt[len(f.renders)] = 2.0 }, false, 1},
		{"wrong words", func() { f.heard[len(f.renders)] = "совсем другие слова здесь звучат" }, false, 1},
	}
	for i, c := range cases {
		c.setup()
		s := spec
		s.Text, s.Seed = text, int64(100+i)
		ref, rendered, err := tk.take(context.Background(), s, 0)
		if err != nil || !rendered {
			t.Fatalf("%s: %v rendered=%v", c.name, err, rendered)
		}
		if ref.Passed != c.passed || len(ref.Reasons) != c.reasons {
			t.Errorf("%s: %+v", c.name, ref)
		}
	}
}

// A take with a sidecar is neither rendered nor transcribed again (Q3);
// a wav without a sidecar (crash between) is transcribed, not rendered.
// Mutation: skip the sidecar read in take -> second call hears again -> RED.
func TestTakeIsCached(t *testing.T) {
	f := newFakePorts(t)
	tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
	s := takeSpec{V: takeKeyVersion, Engine: "e", Voice: "nar", Mode: cloneReference, Text: "Раз два три.", Seed: 7, Cfg: 2, Steps: 10}
	for i := 0; i < 2; i++ {
		if _, _, err := tk.take(context.Background(), s, 0); err != nil {
			t.Fatal(err)
		}
	}
	if len(f.renders) != 1 || f.hears != 1 {
		t.Fatalf("renders %d hears %d, want 1/1", len(f.renders), f.hears)
	}
	if err := os.Remove(filepath.Join(tk.dir, s.key()+".json")); err != nil {
		t.Fatal(err)
	}
	if _, rendered, err := tk.take(context.Background(), s, 0); err != nil || rendered || f.hears != 2 {
		t.Fatalf("rendered=%v hears=%d err=%v", rendered, f.hears, err)
	}
}

// A non-voxcpm2 take (a degraded qwen render) is refused, never stored.
func TestTakeRefusesOtherModels(t *testing.T) {
	f := newFakePorts(t)
	tk := &taker{ports: &qwenPorts{f}, dir: t.TempDir(), quiet: noQuiet}
	s := takeSpec{V: takeKeyVersion, Text: "Текст.", Seed: 1, Cfg: 2, Steps: 10}
	if _, _, err := tk.take(context.Background(), s, 0); err == nil {
		t.Fatal("a qwen take was accepted")
	}
	if entries, _ := os.ReadDir(tk.dir); len(entries) != 0 {
		t.Fatalf("files written: %v", entries)
	}
}

type qwenPorts struct{ *fakePorts }

func (q *qwenPorts) Render(ctx context.Context, p renderParams) (*synthOut, error) {
	out, err := q.fakePorts.Render(ctx, p)
	if err == nil {
		out.Model = config.TTSModelQwen
	}
	return out, err
}
