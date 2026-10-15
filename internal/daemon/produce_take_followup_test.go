package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Followups of the take-core review (#149), one test each.

func followupSpec(text string) takeSpec {
	return takeSpec{V: takeKeyVersion, Mode: cloneReference, Text: text, Seed: 7, Cfg: 2, Steps: 10}
}

// A cached WAV that does not decode is a cache miss: the take is rendered
// again, with or without its sidecar (#149.1).
// Mutation: produce_take.go take, return the readClip error instead of
// falling through to render -> both cases error -> RED.
func TestCorruptCachedWAVIsACacheMiss(t *testing.T) {
	garbage := []byte("RIFF....not a wav")
	for name, dropSidecar := range map[string]bool{"with sidecar": false, "orphan wav": true} {
		f := newFakePorts(t)
		tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
		s := followupSpec("Раз два три четыре.")
		if _, _, err := tk.take(context.Background(), s, 0); err != nil {
			t.Fatal(err)
		}
		wav := filepath.Join(tk.dir, s.key()+".wav")
		if err := os.WriteFile(wav, garbage, 0o600); err != nil {
			t.Fatal(err)
		}
		if dropSidecar {
			if err := os.Remove(filepath.Join(tk.dir, s.key()+".json")); err != nil {
				t.Fatal(err)
			}
		}
		ref, rendered, err := tk.take(context.Background(), s, 0)
		if err != nil || !rendered || len(f.renders) != 2 || !ref.Passed {
			t.Fatalf("%s: err=%v rendered=%v renders=%d %+v", name, err, rendered, len(f.renders), ref)
		}
		raw, _ := os.ReadFile(wav)
		if _, err := pcm.Decode(raw); err != nil {
			t.Errorf("%s: the corrupt file was not replaced: %v", name, err)
		}
	}
}

// A cached WAV with a valid header and no samples is also a miss.
func TestEmptyCachedWAVIsACacheMiss(t *testing.T) {
	f := newFakePorts(t)
	tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
	s := followupSpec("Раз два три четыре.")
	if err := os.WriteFile(filepath.Join(tk.dir, s.key()+".wav"), pcm.Clip{Rate: 48000}.Encode(), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, rendered, err := tk.take(context.Background(), s, 0); err != nil || !rendered {
		t.Fatalf("err=%v rendered=%v", err, rendered)
	}
}

// Dropped <unk> tokens are bounded by the dashes and punctuation of the
// spoken text; any more count as errors, so babble cannot hide behind them
// (#149.3).
// Mutation: produce_take.go gateWith, errs += extra -> errs += 0 -> RED.
// Mutation: produce_take.go gateWith, extra := unk - punct -> extra := 0 -> RED.
func TestGateBoundsDroppedUnknownTokens(t *testing.T) {
	plain := "один два три четыре пять шесть семь восемь девять десять"
	heard := wordsOf(plain + " <unk> <unk> <unk>")
	fails, errs, _ := gateTake(plain, toneClip(2, 0), heard)
	if errs != 3 || len(fails) != 1 {
		t.Errorf("10 right words + 3 <unk> and no punctuation: errs=%d fails=%v, want 3 errors and a fail", errs, fails)
	}
	dashed := "один — два — три четыре пять шесть семь восемь девять десять"
	spoken := "один <unk> два <unk> три четыре пять шесть семь восемь девять десять"
	if fails, errs, _ := gateTake(dashed, toneClip(2, 0), wordsOf(spoken)); errs != 0 || len(fails) != 0 {
		t.Errorf("the two dashes' <unk> were counted: errs=%d fails=%v", errs, fails)
	}
	if _, errs, _ := gateTake(dashed, toneClip(2, 0), wordsOf(spoken+" <unk>")); errs != 1 {
		t.Errorf("one <unk> past the two dashes: errs=%d, want 1", errs)
	}
}

// A take that is wholly silent is rejected with a reason, even when it is a
// single word with no transcript error (#149.4).
// Mutation: produce_take.go gateWith, delete the empty-Trim check -> RED.
func TestSilentTakeIsRejected(t *testing.T) {
	silent := pcm.Clip{Rate: 48000, S: make([]int16, 48000)}
	fails, errs, _ := gateTake("Привет.", silent, wordsOf("Привет."))
	if errs != 0 {
		t.Fatalf("fixture: want a clean transcript, errs=%d", errs)
	}
	if len(fails) != 1 || !strings.Contains(fails[0], "silent") {
		t.Fatalf("a silent one-word take passed: %v", fails)
	}
	if fails, _, _ := gateTake("Привет.", toneClip(1, 0), wordsOf("Привет.")); len(fails) != 0 {
		t.Errorf("a clean take failed: %v", fails)
	}
}

// orderPorts records Render and Hear into one shared event log.
type orderPorts struct {
	*fakePorts
	log *eventLog
}

type eventLog struct {
	mu sync.Mutex
	ev []string
}

func (l *eventLog) add(e string) { l.mu.Lock(); l.ev = append(l.ev, e); l.mu.Unlock() }
func (l *eventLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Join(l.ev, ",")
}

func (o *orderPorts) Render(ctx context.Context, p renderParams) (*synthOut, error) {
	o.log.add("render")
	return o.fakePorts.Render(ctx, p)
}

func (o *orderPorts) Hear(ctx context.Context, wav string) ([]voices.Word, error) {
	o.log.add("hear")
	return o.fakePorts.Hear(ctx, wav)
}

// D12: the taker yields to dictation once before it renders and once before
// it transcribes (#149.5).
// Mutation: produce_take.go render, delete the t.quiet(ctx) call -> "render,quiet,hear" -> RED.
// Mutation: produce_take.go gate, delete the t.quiet(ctx) call -> "quiet,render,hear" -> RED.
func TestTakerYieldsBeforeRenderAndBeforeHear(t *testing.T) {
	log := &eventLog{}
	tk := &taker{ports: &orderPorts{newFakePorts(t), log}, dir: t.TempDir(),
		quiet: func(context.Context) error { log.add("quiet"); return nil }}
	if _, _, err := tk.take(context.Background(), followupSpec("Раз два три."), 0); err != nil {
		t.Fatal(err)
	}
	if got, want := log.String(), "quiet,render,quiet,hear"; got != want {
		t.Fatalf("event order %q, want %q", got, want)
	}
}

// A sidecar planted under another take's name is not trusted: the take is
// judged afresh from its own WAV (#149.6).
// Mutation: produce_take.go take, drop `&& d.Ref.Key == key` -> the planted
// sidecar is used, no transcription happens -> RED.
func TestSidecarForAnotherTakeIsIgnored(t *testing.T) {
	f := newFakePorts(t)
	tk := &taker{ports: f, dir: t.TempDir(), quiet: noQuiet}
	s := followupSpec("Раз два три четыре.")
	if _, _, err := tk.take(context.Background(), s, 0); err != nil {
		t.Fatal(err)
	}
	side := filepath.Join(tk.dir, s.key()+".json")
	d, err := readDetail(side)
	if err != nil {
		t.Fatal(err)
	}
	other := followupSpec("Совсем другой текст.")
	d.Ref.Key, d.Heard = other.key(), wordsOf("совсем другой текст")
	writeDetailT(t, side, d)
	ref, rendered, err := tk.take(context.Background(), s, 0)
	if err != nil || rendered {
		t.Fatalf("err=%v rendered=%v", err, rendered)
	}
	if f.hears != 2 {
		t.Fatalf("hears=%d: the planted sidecar was trusted", f.hears)
	}
	if !ref.Passed || ref.Key != s.key() {
		t.Fatalf("verdict from the planted words: %+v", ref)
	}
}

func writeDetailT(t *testing.T, path string, d takeDetail) {
	t.Helper()
	raw, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}
