package voices

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// seedVoice writes <name>.wav (secs of silence) and <name>.json directly,
// the way a pre-fix daemon left them.
func seedVoice(t *testing.T, s *Store, name string, secs float64, refText string) {
	t.Helper()
	if err := os.WriteFile(s.WAVPath(name), testutil.SilentWAV(secs), 0o644); err != nil {
		t.Fatal(err)
	}
	meta := `{"name":"` + name + `","ref_text":"` + refText + `","created":"2026-10-04T14:28:00Z"}`
	if err := os.WriteFile(s.metaPath(name), []byte(meta), 0o644); err != nil {
		t.Fatal(err)
	}
}

func words90() string { return strings.TrimSpace(strings.Repeat("word ", 90)) }

func TestDiagnose(t *testing.T) {
	tests := []struct {
		name string
		v    Voice
		dur  float64
		want bool
	}{
		{"at cap with text", Voice{RefText: "a b c"}, 20, true},
		{"just under cap tolerance", Voice{RefText: "a b c"}, 19.96, true},
		{"too fast", Voice{RefText: words90()}, 13, true},
		{"70 words in 13 s", Voice{RefText: strings.TrimSpace(strings.Repeat("w ", 70))}, 13, true},
		{"a real fast reader, 53 words in 12.98 s", Voice{RefText: strings.TrimSpace(strings.Repeat("w ", 53))}, 12.98, false},
		{"healthy", Voice{RefText: strings.TrimSpace(strings.Repeat("w ", 11))}, 5.4, false},
		{"at cap but no text", Voice{}, 20, false},
		{"slow russian", Voice{RefText: strings.TrimSpace(strings.Repeat("w ", 18))}, 17.2, false},
	}
	for _, tt := range tests {
		if got := Diagnose(tt.v, tt.dur) != ""; got != tt.want {
			t.Errorf("%s: Diagnose broken = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// A stored 20.0 s voice with 90 words is repaired and its original pair kept.
// Mutation: internal/voices/repair.go Diagnose — delete the `dur >=
// MaxRefSeconds-capEpsilon` branch AND raise MaxPlausibleWordsPerSecond to
// 100 (detection disabled) -> RED (nothing repaired).
func TestRepairCappedVoice(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "longref", 20, words90())
	calls := 0
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), &calls))

	r, err := s.PrepareRepair(context.Background(), "longref")
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v; want a repair", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	v, err := s.Get("longref")
	if err != nil {
		t.Fatal(err)
	}
	if v.RefText != r.NewText || v.RefText == words90() || !strings.HasPrefix(v.RefText, "w0 w1") {
		t.Fatalf("ref_text = %q, want the transcript words", v.RefText)
	}
	if v.Created.Format("2006-01-02") != "2026-10-04" {
		t.Fatalf("Created not preserved: %v", v.Created)
	}
	if d, _ := WAVSeconds(s.WAVPath("longref")); d > MaxRefSeconds+0.01 || d < 15 {
		t.Fatalf("repaired clip is %.2f s", d)
	}
	old, err := os.ReadFile(s.backupPath("longref", ".json"))
	if err != nil || !strings.Contains(string(old), words90()) {
		t.Fatalf("backup json missing or altered: %v %q", err, old)
	}
	if d, err := WAVSeconds(s.backupPath("longref", ".wav")); err != nil || math.Abs(d-20) > 0.01 {
		t.Fatalf("backup wav = %.2f s, %v; want the original 20 s", d, err)
	}
	list, _ := s.List()
	if len(list) != 1 || list[0].Name != "longref" {
		t.Fatalf("List = %+v; the .orig backup must not appear as a voice", list)
	}
}

// A voice under the cap but with an impossible words/s gets its text replaced
// and its audio left whole.
func TestRepairFastTranscriptKeepsAudio(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "fastref", 12.98, strings.TrimSpace(strings.Repeat("w ", 70)))
	calls := 0
	s.SetTranscriber(fixedWords(speechWords(35, 0.3, 0.07, 9), &calls))
	r, err := s.PrepareRepair(context.Background(), "fastref")
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	if d, _ := WAVSeconds(s.WAVPath("fastref")); math.Abs(d-12.98) > 0.02 {
		t.Fatalf("audio changed: %.2f s", d)
	}
	v, _ := s.Get("fastref")
	if n := len(strings.Fields(v.RefText)); n != 35 {
		t.Fatalf("ref_text has %d words, want 35", n)
	}
}

// A completed repair (backup + healthy, different main files) is left alone;
// a healthy voice is not even transcribed.
func TestRepairLeavesHealthyAndRepairedAlone(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "native", 5.4, "one two three four five six seven eight nine ten eleven")
	seedVoice(t, s, "done", 10, "a cut and healthy transcript of ten words or so here")
	for ext, content := range map[string]string{".json": `{"name":"done","ref_text":"` + words90() + `"}`, ".wav": "orig"} {
		if err := os.WriteFile(s.backupPath("done", ext), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(s.backupPath("done", ".wav"), testutil.SilentWAV(20), 0o644); err != nil {
		t.Fatal(err)
	}
	calls := 0
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), &calls))
	for _, n := range []string{"native", "done"} {
		if r, err := s.PrepareRepair(context.Background(), n); r != nil || err != nil {
			t.Fatalf("%s: PrepareRepair = %v, %v; want nil, nil", n, r, err)
		}
	}
	if calls != 0 {
		t.Fatalf("transcriber called %d times for healthy/already-repaired voices", calls)
	}
}

// A correct at-cap clip (its text IS the transcript) is neither cut nor
// rewritten.
// Mutation: internal/voices/repair.go plan — delete the TextsMatch early return -> RED.
func TestRepairCorrectCappedClipUntouched(t *testing.T) {
	s, _ := newStore(t)
	words := speechWords(60, 0.3, 0.03, 6) // 19.8 s of speech
	text := joinWords(words)
	seedVoice(t, s, "exact", 20, text)
	s.SetTranscriber(fixedWords(words, new(int)))
	if r, err := s.PrepareRepair(context.Background(), "exact"); r != nil || err != nil {
		t.Fatalf("PrepareRepair = %v, %v; want nil, nil for a correct transcript", r, err)
	}
	if _, err := os.Stat(s.backupPath("exact", ".json")); err == nil {
		t.Fatal("backup written for a voice that needed no repair")
	}
}

// Untranscribable scripts are never rewritten.
// Mutation: internal/voices/repair.go PrepareRepair — delete the
// `Script(srcText) == ""` refusal -> RED.
func TestRepairNonLatinLeftAlone(t *testing.T) {
	for name, text := range map[string]string{
		"cjk":    strings.Repeat("今天天气很好我们一起去公园玩。", 6),
		"arabic": strings.Repeat("الطقس جميل اليوم ", 30),
	} {
		t.Run(name, func(t *testing.T) {
			s, _ := newStore(t)
			seedVoice(t, s, "zh", 20, text)
			calls := 0
			s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), &calls))
			r, err := s.PrepareRepair(context.Background(), "zh")
			if r != nil || !errors.Is(err, ErrScript) {
				t.Fatalf("PrepareRepair = %v, %v; want ErrScript", r, err)
			}
			if calls != 0 {
				t.Fatalf("STT called %d times", calls)
			}
		})
	}
	// Latin text whose transcript is Cyrillic (script differs): left alone too.
	s, _ := newStore(t)
	seedVoice(t, s, "x", 20, words90())
	s.SetTranscriber(func(context.Context, string) ([]Word, error) {
		return []Word{{W: "Привет", S: 0, E: 1}, {W: "мир.", S: 1.1, E: 2}}, nil
	})
	if r, err := s.PrepareRepair(context.Background(), "x"); r != nil || !errors.Is(err, ErrScript) {
		t.Fatalf("script mismatch: %v, %v; want ErrScript", r, err)
	}
}

// A re-add between PrepareRepair (outside the lock) and Apply must not be
// overwritten by the cut of the old clip.
// Mutation: internal/voices/repair.go Apply — `!cur.equal(r.from)` -> `false` -> RED.
func TestRepairApplyRefusesChangedVoice(t *testing.T) {
	cases := map[string]func(t *testing.T, s *Store){
		"same text, new audio and created": func(t *testing.T, s *Store) {
			meta := `{"name":"longref","ref_text":"` + words90() + `","created":"2026-10-15T00:00:00Z"}`
			if err := os.WriteFile(s.WAVPath("longref"), testutil.SilentWAV(19), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(s.metaPath("longref"), []byte(meta), 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"new text": func(t *testing.T, s *Store) { seedVoice(t, s, "longref", 20, "brand new transcript") },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			s, _ := newStore(t)
			seedVoice(t, s, "longref", 20, words90())
			s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), new(int)))
			r, err := s.PrepareRepair(context.Background(), "longref")
			if err != nil || r == nil {
				t.Fatalf("PrepareRepair = %v, %v", r, err)
			}
			mutate(t, s)
			before, _ := os.ReadFile(s.WAVPath("longref"))
			if err := r.Apply(); !errors.Is(err, ErrChanged) {
				t.Fatalf("Apply = %v, want ErrChanged", err)
			}
			after, _ := os.ReadFile(s.WAVPath("longref"))
			if !bytes.Equal(before, after) {
				t.Fatal("the re-added clip was overwritten")
			}
			if _, err := os.Stat(s.backupPath("longref", ".json")); err == nil {
				t.Fatal("backup written for a refused repair")
			}
		})
	}
}

// Crash safety. A rename that fails at step N stands in for a kill there; the
// next start (a fresh Store on the same dir) must converge to a repaired voice
// with the ORIGINAL pair intact in the backup.
// Mutation: internal/voices/repair.go Apply — swap the backup loop's order to
// {".json", ".wav"} (marker first) -> RED for the "backup .wav" step.
func TestRepairConvergesAfterCrashAtEveryStep(t *testing.T) {
	steps := []struct {
		name string
		fail func(old, new string) bool
	}{
		{"backup wav", func(_, n string) bool { return strings.HasSuffix(n, ".orig.wav") }},
		{"backup json (marker)", func(_, n string) bool { return strings.HasSuffix(n, ".orig.json") }},
		{"main wav", func(_, n string) bool { return strings.HasSuffix(n, "/longref.wav") }},
		{"main json", func(_, n string) bool { return strings.HasSuffix(n, "/longref.json") }},
	}
	for _, st := range steps {
		t.Run(st.name, func(t *testing.T) {
			s, _ := newStore(t)
			seedVoice(t, s, "longref", 20, words90())
			origWAV, _ := os.ReadFile(s.WAVPath("longref"))
			origJSON, _ := os.ReadFile(s.metaPath("longref"))
			tr := fixedWords(speechWords(60, 0.3, 0.1, 6), new(int))
			s.SetTranscriber(tr)
			s.rename = func(o, n string) error {
				if st.fail(o, n) {
					return errors.New("simulated crash")
				}
				return os.Rename(o, n)
			}
			r, err := s.PrepareRepair(context.Background(), "longref")
			if err != nil || r == nil {
				t.Fatalf("PrepareRepair = %v, %v", r, err)
			}
			if err := r.Apply(); err == nil {
				t.Fatal("Apply survived the simulated crash")
			}

			// Restart: a new Store, SweepTemp as the daemon does, a normal pass.
			s2, err := New(s.dir)
			if err != nil {
				t.Fatal(err)
			}
			s2.SetTranscriber(tr)
			if err := s2.SweepTemp(); err != nil {
				t.Fatal(err)
			}
			r2, err := s2.PrepareRepair(context.Background(), "longref")
			if err != nil || r2 == nil {
				t.Fatalf("after the crash PrepareRepair = %v, %v; want a repair (the voice is still broken)", r2, err)
			}
			if err := r2.Apply(); err != nil {
				t.Fatal(err)
			}
			v, _ := s2.Get("longref")
			if v.RefText == words90() || !strings.HasPrefix(v.RefText, "w0 w1") {
				t.Fatalf("ref_text after convergence = %q", v.RefText)
			}
			if d, _ := WAVSeconds(s2.WAVPath("longref")); d > MaxRefSeconds || d < 10 {
				t.Fatalf("clip = %.2f s", d)
			}
			bw, _ := os.ReadFile(s2.backupPath("longref", ".wav"))
			bj, _ := os.ReadFile(s2.backupPath("longref", ".json"))
			if !bytes.Equal(bw, origWAV) || !bytes.Equal(bj, origJSON) {
				t.Fatal("the backup is not the byte-identical original pair")
			}
			// And now it is done: a further start does nothing.
			if r3, err := s2.PrepareRepair(context.Background(), "longref"); r3 != nil || err != nil {
				t.Fatalf("third pass = %v, %v; want nil, nil", r3, err)
			}
			left, _ := filepath.Glob(filepath.Join(s2.dir, ".normalize-*"))
			if len(left) != 0 {
				t.Fatalf("temp files left: %v", left)
			}
		})
	}
}

// A backup beside a voice that is still broken is not a completed repair: it
// is retried. When the main files carry the original text the retry derives
// from the BACKUP's audio (the main WAV may already be a cut).
// Mutation: internal/voices/repair.go PrepareRepair — replace the
// `haveBackup && … Diagnose(*v, mainDur) == ""` early return with
// `haveBackup` (backup = done) -> RED.
func TestRepairRetriesBrokenVoiceWithBackup(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "longref", 20, words90())
	// a backup exists, main still has the original text (repair died after the marker)
	if err := os.WriteFile(s.backupPath("longref", ".wav"), testutil.SilentWAV(20), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(s.backupPath("longref", ".json"), []byte(`{"name":"longref","ref_text":"`+words90()+`"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), new(int)))
	r, err := s.PrepareRepair(context.Background(), "longref")
	if err != nil || r == nil || !r.Retry {
		t.Fatalf("PrepareRepair = %+v, %v; want a retry", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	if v, _ := s.Get("longref"); v.RefText == words90() {
		t.Fatal("still broken after the retry")
	}
	if bj, _ := os.ReadFile(s.backupPath("longref", ".json")); !strings.Contains(string(bj), words90()) {
		t.Fatal("backup json overwritten by the retry")
	}
}

func TestRemoveDeletesRepairBackup(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "longref", 20, words90())
	for _, ext := range []string{".wav", ".json"} {
		if err := os.WriteFile(s.backupPath("longref", ext), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Remove("longref"); err != nil {
		t.Fatal(err)
	}
	left, _ := filepath.Glob(filepath.Join(s.dir, "longref*"))
	if len(left) != 0 {
		t.Fatalf("files left after Remove: %v", left)
	}
}

// A fresh add of a name supersedes a stale repair backup of an older voice.
func TestAddDropsStaleBackup(t *testing.T) {
	s, dir := newStore(t)
	for _, ext := range []string{".wav", ".json"} {
		if err := os.WriteFile(s.backupPath("ben", ext), []byte("stale"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Add(context.Background(), "ben", testutil.WriteTinyWAV(t, dir, "c.wav"), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.backupPath("ben", ".json")); err == nil {
		t.Fatal("stale backup survived a re-add")
	}
}

func TestRepairWithoutTranscriber(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "longref", 20, words90())
	if _, err := s.PrepareRepair(context.Background(), "longref"); !errors.Is(err, ErrNoTranscriber) {
		t.Fatalf("err = %v, want ErrNoTranscriber", err)
	}
	if v, _ := s.Get("longref"); v.RefText != words90() {
		t.Fatal("voice modified without a transcriber")
	}
	if _, err := os.Stat(filepath.Join(s.dir, "longref.orig.json")); err == nil {
		t.Fatal("backup written for a repair that did not happen")
	}
}

// An at-cap voice whose text runs a few words past its audio must be repaired
// (the overall word ratio alone calls it healthy: 0.84-0.9).
// Mutation: internal/voices/repair.go plan — call TextsMatch instead of
// TranscriptMatches -> RED for capped-overrun-11, -6 and -4.
func TestRepairTailOverrunVoices(t *testing.T) {
	raw, err := os.ReadFile("testdata/transcript_tails.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []struct {
		Name    string `json:"name"`
		RefText string `json:"ref_text"`
		Stt     string `json:"stt"`
	}
	if err := json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatal(err)
	}
	wantRepair := map[string]bool{"capped-overrun-35": true, "capped-overrun-48": true, "capped-overrun-11": true, "capped-overrun-6": true, "capped-overrun-4": true}
	for _, f := range fixtures {
		t.Run(f.Name, func(t *testing.T) {
			s, _ := newStore(t)
			meta, _ := json.Marshal(map[string]any{"name": f.Name, "ref_text": f.RefText, "created": "2026-10-04T14:28:00Z"})
			if err := os.WriteFile(s.WAVPath(f.Name), testutil.SilentWAV(20), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(s.metaPath(f.Name), meta, 0o644); err != nil {
				t.Fatal(err)
			}
			heard := strings.Fields(f.Stt)
			words := make([]Word, len(heard))
			step := 19.8 / float64(len(heard))
			for i, w := range heard {
				words[i] = Word{W: w, S: float64(i) * step, E: float64(i)*step + step*0.9}
			}
			s.SetTranscriber(fixedWords(words, new(int)))
			r, err := s.PrepareRepair(context.Background(), f.Name)
			if err != nil {
				t.Fatal(err)
			}
			if got := r != nil; got != wantRepair[f.Name] {
				t.Fatalf("repair planned = %v, want %v", got, wantRepair[f.Name])
			}
			if r != nil {
				r.Discard()
			}
		})
	}
}

// startAgain is a daemon restart: a fresh Store on the same directory, as
// main does, with SweepTemp.
func startAgain(t *testing.T, s *Store, tr Transcriber) *Store {
	t.Helper()
	s2, err := New(s.dir)
	if err != nil {
		t.Fatal(err)
	}
	s2.SetTranscriber(tr)
	if err := s2.SweepTemp(); err != nil {
		t.Fatal(err)
	}
	return s2
}

// A voice whose clip is at the cap but whose transcript is right is
// transcribed once, not on every daemon start; any change to what the verdict
// was computed from brings the transcription back.
// Mutation: internal/voices/repair.go PrepareRepair — drop the verdictKnown
// early return -> RED "starts" (transcribed on the second start).
// Mutation: internal/voices/repair.go verdictKey — build the key without
// mtime -> RED "same size, new mtime".
func TestRepairVerdictCachedAcrossStarts(t *testing.T) {
	words := speechWords(60, 0.3, 0.03, 6) // 19.8 s of speech, a correct 20 s clip
	text := joinWords(words)
	setup := func(t *testing.T) (*Store, *int, Transcriber) {
		s, _ := newStore(t)
		seedVoice(t, s, "exact", 20, text)
		calls := new(int)
		tr := fixedWords(words, calls)
		s.SetTranscriber(tr)
		if r, err := s.PrepareRepair(context.Background(), "exact"); r != nil || err != nil || *calls != 1 {
			t.Fatalf("first start: %v, %v, %d calls; want nil, nil, 1", r, err, *calls)
		}
		return s, calls, tr
	}
	t.Run("starts", func(t *testing.T) {
		s, calls, tr := setup(t)
		for range 2 {
			s = startAgain(t, s, tr)
			if r, err := s.PrepareRepair(context.Background(), "exact"); r != nil || err != nil {
				t.Fatalf("PrepareRepair = %v, %v", r, err)
			}
		}
		if *calls != 1 {
			t.Fatalf("transcriber called %d times across three starts, want 1", *calls)
		}
	})
	t.Run("same size, new mtime", func(t *testing.T) {
		s, calls, tr := setup(t)
		later := time.Now().Add(time.Hour)
		if err := os.Chtimes(s.WAVPath("exact"), later, later); err != nil {
			t.Fatal(err)
		}
		s = startAgain(t, s, tr)
		if _, err := s.PrepareRepair(context.Background(), "exact"); err != nil {
			t.Fatal(err)
		}
		if *calls != 2 {
			t.Fatalf("transcriber called %d times, want 2: a changed file must be re-checked", *calls)
		}
	})
	t.Run("same clip, new ref_text", func(t *testing.T) {
		s, calls, tr := setup(t)
		meta := `{"name":"exact","ref_text":"` + text + ` extra","created":"2026-10-04T14:28:00Z"}`
		if err := os.WriteFile(s.metaPath("exact"), []byte(meta), 0o644); err != nil {
			t.Fatal(err)
		}
		s = startAgain(t, s, tr)
		if _, err := s.PrepareRepair(context.Background(), "exact"); err != nil {
			t.Fatal(err)
		}
		if *calls != 2 {
			t.Fatalf("transcriber called %d times, want 2: an edited transcript must be re-checked", *calls)
		}
	})
	t.Run("repair logic changed", func(t *testing.T) {
		s, calls, tr := setup(t)
		defer func(v int) { repairLogicVersion = v }(repairLogicVersion)
		repairLogicVersion++
		s = startAgain(t, s, tr)
		if _, err := s.PrepareRepair(context.Background(), "exact"); err != nil {
			t.Fatal(err)
		}
		if *calls != 2 {
			t.Fatalf("transcriber called %d times, want 2: new repair logic must re-check", *calls)
		}
	})
	t.Run("a broken verdict is not cached", func(t *testing.T) {
		s, _ := newStore(t)
		seedVoice(t, s, "longref", 20, words90())
		calls := new(int)
		tr := fixedWords(speechWords(60, 0.3, 0.1, 6), calls)
		s.SetTranscriber(tr)
		r, err := s.PrepareRepair(context.Background(), "longref")
		if err != nil || r == nil {
			t.Fatalf("PrepareRepair = %v, %v", r, err)
		}
		r.Discard() // not applied: the next start must see the voice broken again
		s = startAgain(t, s, tr)
		if r, err = s.PrepareRepair(context.Background(), "longref"); err != nil || r == nil {
			t.Fatalf("second start = %v, %v; a broken voice must be offered again", r, err)
		}
		r.Discard()
	})
}

// The verdict is bound to the clip's bytes, not just to its size and mtime, and
// to the tail check's parameters.
// Mutation: internal/voices/repair.go verdictKey — hash nothing of the clip
// (drop the io.Copy into hc) -> RED "same mtime, different bytes".
// Mutation: internal/voices/repair.go verdictKey — drop tailParams() from the
// key -> RED "tail parameters".
func TestRepairVerdictKeyBindings(t *testing.T) {
	words := speechWords(60, 0.3, 0.03, 6)
	text := joinWords(words)
	setup := func(t *testing.T) (*Store, *int, Transcriber) {
		s, _ := newStore(t)
		seedVoice(t, s, "exact", 20, text)
		calls := new(int)
		tr := fixedWords(words, calls)
		s.SetTranscriber(tr)
		if _, err := s.PrepareRepair(context.Background(), "exact"); err != nil || *calls != 1 {
			t.Fatalf("first start: %v, %d calls", err, *calls)
		}
		return s, calls, tr
	}
	recheck := func(t *testing.T, s *Store, calls *int, tr Transcriber, what string) {
		t.Helper()
		s = startAgain(t, s, tr)
		if _, err := s.PrepareRepair(context.Background(), "exact"); err != nil {
			t.Fatal(err)
		}
		if *calls != 2 {
			t.Fatalf("transcriber called %d times, want 2: %s must be re-checked", *calls, what)
		}
	}
	t.Run("same mtime, different bytes", func(t *testing.T) {
		s, calls, tr := setup(t)
		st, _ := os.Stat(s.WAVPath("exact"))
		b := testutil.SilentWAV(20)
		b[len(b)-1] ^= 0x01 // same length
		if err := os.WriteFile(s.WAVPath("exact"), b, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(s.WAVPath("exact"), st.ModTime(), st.ModTime()); err != nil {
			t.Fatal(err)
		}
		recheck(t, s, calls, tr, "a replaced clip")
	})
	t.Run("tail parameters", func(t *testing.T) {
		s, _ := newStore(t)
		seedVoice(t, s, "exact", 20, text)
		key, err := s.verdictKey(s.WAVPath("exact"), text)
		if err != nil {
			t.Fatal(err)
		}
		want := fmt.Sprintf("%d,%d,%d", anchorWords, anchorWindow, anchorNeed)
		if !strings.Contains(key, "|tail:"+want+",") {
			t.Fatalf("key %q does not carry the tail constants %s", key, want)
		}
	})
}

// Remove takes the voice's verdict with it.
// Mutation: internal/voices/store.go Remove — delete the forgetVerdict call
// -> RED.
func TestRemoveDropsVerdict(t *testing.T) {
	words := speechWords(60, 0.3, 0.03, 6)
	s, _ := newStore(t)
	seedVoice(t, s, "exact", 20, joinWords(words))
	seedVoice(t, s, "other", 20, joinWords(words))
	s.SetTranscriber(fixedWords(words, new(int)))
	for _, n := range []string{"exact", "other"} {
		if _, err := s.PrepareRepair(context.Background(), n); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.readVerdicts()) != 2 {
		t.Fatalf("verdicts = %v, want two", s.readVerdicts())
	}
	if err := s.Remove("exact"); err != nil {
		t.Fatal(err)
	}
	if v := s.readVerdicts(); len(v) != 1 || v["other"] == "" {
		t.Fatalf("verdicts after Remove = %v, want only other", v)
	}
}

// Remove of a voice whose files are already gone still drops its verdict.
// Mutation: internal/voices/store.go Remove — move forgetVerdict below the
// `if missing { return ErrNotFound }` return -> RED.
func TestRemoveMissingFilesDropsVerdict(t *testing.T) {
	words := speechWords(60, 0.3, 0.03, 6)
	s, _ := newStore(t)
	seedVoice(t, s, "exact", 20, joinWords(words))
	s.SetTranscriber(fixedWords(words, new(int)))
	if _, err := s.PrepareRepair(context.Background(), "exact"); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{s.WAVPath("exact"), s.metaPath("exact")} {
		if err := os.Remove(p); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Remove("exact"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Remove = %v, want ErrNotFound", err)
	}
	if v := s.readVerdicts(); len(v) != 0 {
		t.Fatalf("verdicts = %v, want none", v)
	}
}

// Healthy at-cap voices whose transcript differs from ref_text only at the
// very end (the recognizer adds, splits or drops a word there, or writes
// fillers) are left alone: rewriting a voice the user did not ask to change is
// worse than the bleed. A reference running past the audio is still repaired.
// Regression guard for the tail check in tail.go.
// Mutation: internal/voices/tail.go anchorWindow 6 -> 1 -> RED for the
// healthy trailing-word cases.
func TestRepairTailEdgesEndToEnd(t *testing.T) {
	filler := func(prefix string, n int, from rune) []string { // distinct letter-only words
		out := make([]string, n)
		for i := range out {
			out[i] = prefix + string(from+rune(i%26)) + string(from+rune(i/26))
		}
		return out
	}
	timed := func(ws []string, step float64) []Word {
		out := make([]Word, len(ws))
		for i, w := range ws {
			out[i] = Word{W: w, S: float64(i) * step, E: float64(i)*step + step*0.75}
		}
		return out
	}
	cat := func(parts ...[]string) []string {
		var out []string
		for _, p := range parts {
			out = append(out, p...)
		}
		return out
	}
	sp := strings.Fields
	lat, cyr := filler("w", 55, 'a'), filler("с", 55, 'а')
	cases := []struct {
		name         string
		ref, heard   []string
		wantRepaired bool
		step         float64 // seconds per heard word; 0 = 0.4 (58+ words: speech runs to the 20 s clip end)
	}{
		{"healthy: trailing you", append(append([]string{}, lat...), "see", "you", "tomorrow"), append(append([]string{}, lat...), "see", "you", "tomorrow", "you"), false, 0},
		{"healthy: trailing thank you", append(append([]string{}, lat...), "see", "you", "tomorrow"), append(append([]string{}, lat...), "see", "you", "tomorrow", "thank", "you"), false, 0},
		{"healthy: trailing ага", append(append([]string{}, cyr...), "увидимся", "завтра", "вечером"), append(append([]string{}, cyr...), "увидимся", "завтра", "вечером", "ага"), false, 0},
		{"healthy: tonight split", append(append([]string{}, lat...), "see", "you", "tonight"), append(append([]string{}, lat...), "see", "you", "to", "night"), false, 0},
		{"healthy: сегодня split", append(append([]string{}, cyr...), "увидимся", "будем", "сегодня"), append(append([]string{}, cyr...), "увидимся", "будем", "се", "годня"), false, 0},
		{"healthy: last word dropped", append(append([]string{}, lat...), "see", "you", "tomorrow"), append(append([]string{}, lat...), "see", "you"), false, 0},
		{"cut: ref runs three words past the audio", append(append([]string{}, lat...), "see", "you", "tomorrow", "at", "the", "station"), append(append([]string{}, lat...), "see", "you", "tomorrow"), true, 0},
		{"healthy: two fillers in the tail", cat(lat, sp("we went to the store today")), cat(lat, sp("we went um to the uh store today")), false, 0},
		{"healthy: two russian fillers in the tail", cat(cyr, sp("мы пошли в магазин сегодня")), cat(cyr, sp("мы э пошли ну в магазин сегодня")), false, 0},
		{"cut: double short-word slip, speech runs to the clip end", cat(lat, sp("so we go to see her")), cat(lat, sp("so we go too sea her")), true, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			step := c.step
			if step == 0 {
				step = 0.4
			}
			s, _ := newStore(t)
			seedVoice(t, s, "tail", 20, strings.Join(c.ref, " "))
			s.SetTranscriber(fixedWords(timed(c.heard, step), new(int)))
			r, err := s.PrepareRepair(context.Background(), "tail")
			if err != nil {
				t.Fatalf("PrepareRepair: %v", err)
			}
			if (r != nil) != c.wantRepaired {
				t.Fatalf("repair = %v, want %v", r != nil, c.wantRepaired)
			}
			if r != nil {
				r.Discard()
			}
		})
	}
}

// Crash safety, judged by outcome. Apply is five mutating operations (backup
// wav, backup json, main json temp, main wav, main json). For every k, the
// process dies after k of them completed; the next start (fresh Store,
// SweepTemp, a normal pass) must leave the voice as exactly the original pair
// or exactly the repaired pair, with the original always recoverable: never a
// lost clip, never a clip with another clip's transcript.
// Mutation: internal/voices/repair.go Apply — move the backup block after the
// main-file writes -> RED for every k ("repaired voice without its original in
// the backup", "neither original nor repaired"). Swapping only the last two
// operations stays GREEN on purpose: the restart heals that state.
func TestRepairCrashAfterEveryOperation(t *testing.T) {
	tr := fixedWords(speechWords(60, 0.3, 0.1, 6), new(int))
	// The repaired outcome, from an uninterrupted run.
	ref, _ := newStore(t)
	seedVoice(t, ref, "longref", 20, words90())
	ref.SetTranscriber(tr)
	r, err := ref.PrepareRepair(context.Background(), "longref")
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	wantText := r.NewText
	const ops = 5
	for k := 0; k <= ops; k++ {
		t.Run(fmt.Sprintf("crash after %d", k), func(t *testing.T) {
			s, _ := newStore(t)
			seedVoice(t, s, "longref", 20, words90())
			origWAV, _ := os.ReadFile(s.WAVPath("longref"))
			s.SetTranscriber(tr)
			n := 0
			step := func() error { // the process is dead from operation k+1 on
				if n++; n > k {
					return errors.New("simulated crash")
				}
				return nil
			}
			s.rename = func(o, nw string) error {
				if err := step(); err != nil {
					return err
				}
				return os.Rename(o, nw)
			}
			s.writeFile = func(p string, b []byte, m os.FileMode) error {
				if err := step(); err != nil {
					return err
				}
				return os.WriteFile(p, b, m)
			}
			r, err := s.PrepareRepair(context.Background(), "longref")
			if err != nil || r == nil {
				t.Fatalf("PrepareRepair = %v, %v", r, err)
			}
			if err := r.Apply(); (err == nil) != (k == ops) {
				t.Fatalf("Apply = %v with %d of %d operations allowed", err, k, ops)
			}

			s2 := startAgain(t, s, tr)
			if r2, err := s2.PrepareRepair(context.Background(), "longref"); err != nil {
				t.Fatalf("restart PrepareRepair: %v", err)
			} else if r2 != nil {
				if err := r2.Apply(); err != nil {
					t.Fatalf("restart Apply: %v", err)
				}
			}
			v, err := s2.Get("longref")
			if err != nil {
				t.Fatalf("voice lost: %v", err)
			}
			wav, err := os.ReadFile(s2.WAVPath("longref"))
			if err != nil {
				t.Fatalf("clip lost: %v", err)
			}
			dur, _ := WAVSeconds(s2.WAVPath("longref"))
			switch {
			case bytes.Equal(wav, origWAV) && v.RefText == words90():
			case v.RefText == wantText && dur < MaxRefSeconds-capEpsilon:
				if bw, err := os.ReadFile(s2.backupPath("longref", ".wav")); err != nil || !bytes.Equal(bw, origWAV) {
					t.Fatalf("repaired voice without its original in the backup: %v", err)
				}
			default:
				t.Fatalf("neither original nor repaired: text %.30q..., clip %.2f s", v.RefText, dur)
			}
			if left, _ := filepath.Glob(filepath.Join(s2.dir, ".normalize-*")); len(left) != 0 {
				t.Fatalf("temp files left: %v", left)
			}
		})
	}
}

// A repair rewrites the transcript only: every other metadata field survives,
// in the main file and in the backup of the original.
// Mutation: internal/voices/repair.go Apply — marshal
// Voice{Name: v.Name, RefText: r.NewText, Created: v.Created} (the old
// three-field literal) instead of the copy of v -> RED.
func TestRepairKeepsVoiceMeta(t *testing.T) {
	s, _ := newStore(t)
	const name = "longref"
	seedVoice(t, s, name, 20, words90())
	calls := 0
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), &calls))
	want := Meta{Engine: "voxcpm2", Style: "calm, warm", DesignedFrom: "a deep narrator"}
	if _, err := s.Update(name, func(v *Voice) { v.Meta = want }); err != nil {
		t.Fatal(err)
	}
	r, err := s.PrepareRepair(context.Background(), name)
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v; want a repair", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	v, err := s.Get(name)
	if err != nil {
		t.Fatal(err)
	}
	if v.Meta != want || v.RefText != r.NewText {
		t.Fatalf("repair dropped metadata: %+v, want %+v", v.Meta, want)
	}
	raw, err := os.ReadFile(s.backupPath(name, ".json"))
	if err != nil || !strings.Contains(string(raw), `"engine":"voxcpm2"`) {
		t.Fatalf("backup of the original lost the metadata: %v %s", err, raw)
	}
}
