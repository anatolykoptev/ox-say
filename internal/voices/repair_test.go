package voices

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

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
		{"emma: a real fast reader, 53 words in 12.98 s", Voice{RefText: strings.TrimSpace(strings.Repeat("w ", 53))}, 12.98, false},
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
	seedVoice(t, s, "snakes", 20, words90())
	calls := 0
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), &calls))

	r, err := s.PrepareRepair(context.Background(), "snakes")
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v; want a repair", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	v, err := s.Get("snakes")
	if err != nil {
		t.Fatal(err)
	}
	if v.RefText != r.NewText || v.RefText == words90() || !strings.HasPrefix(v.RefText, "w0 w1") {
		t.Fatalf("ref_text = %q, want the transcript words", v.RefText)
	}
	if v.Created.Format("2006-01-02") != "2026-10-04" {
		t.Fatalf("Created not preserved: %v", v.Created)
	}
	if d, _ := WAVSeconds(s.WAVPath("snakes")); d > MaxRefSeconds+0.01 || d < 15 {
		t.Fatalf("repaired clip is %.2f s", d)
	}
	old, err := os.ReadFile(s.backupPath("snakes", ".json"))
	if err != nil || !strings.Contains(string(old), words90()) {
		t.Fatalf("backup json missing or altered: %v %q", err, old)
	}
	if d, err := WAVSeconds(s.backupPath("snakes", ".wav")); err != nil || math.Abs(d-20) > 0.01 {
		t.Fatalf("backup wav = %.2f s, %v; want the original 20 s", d, err)
	}
	list, _ := s.List()
	if len(list) != 1 || list[0].Name != "snakes" {
		t.Fatalf("List = %+v; the .orig backup must not appear as a voice", list)
	}
}

// A voice under the cap but with an impossible words/s gets its text replaced
// and its audio left whole.
func TestRepairFastTranscriptKeepsAudio(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "emma", 12.98, strings.TrimSpace(strings.Repeat("w ", 70)))
	calls := 0
	s.SetTranscriber(fixedWords(speechWords(35, 0.3, 0.07, 9), &calls))
	r, err := s.PrepareRepair(context.Background(), "emma")
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	if d, _ := WAVSeconds(s.WAVPath("emma")); math.Abs(d-12.98) > 0.02 {
		t.Fatalf("audio changed: %.2f s", d)
	}
	v, _ := s.Get("emma")
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
			meta := `{"name":"snakes","ref_text":"` + words90() + `","created":"2026-10-15T00:00:00Z"}`
			if err := os.WriteFile(s.WAVPath("snakes"), testutil.SilentWAV(19), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(s.metaPath("snakes"), []byte(meta), 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"new text": func(t *testing.T, s *Store) { seedVoice(t, s, "snakes", 20, "brand new transcript") },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			s, _ := newStore(t)
			seedVoice(t, s, "snakes", 20, words90())
			s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), new(int)))
			r, err := s.PrepareRepair(context.Background(), "snakes")
			if err != nil || r == nil {
				t.Fatalf("PrepareRepair = %v, %v", r, err)
			}
			mutate(t, s)
			before, _ := os.ReadFile(s.WAVPath("snakes"))
			if err := r.Apply(); !errors.Is(err, ErrChanged) {
				t.Fatalf("Apply = %v, want ErrChanged", err)
			}
			after, _ := os.ReadFile(s.WAVPath("snakes"))
			if !bytes.Equal(before, after) {
				t.Fatal("the re-added clip was overwritten")
			}
			if _, err := os.Stat(s.backupPath("snakes", ".json")); err == nil {
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
		{"main wav", func(_, n string) bool { return strings.HasSuffix(n, "/snakes.wav") }},
		{"main json", func(_, n string) bool { return strings.HasSuffix(n, "/snakes.json") }},
	}
	for _, st := range steps {
		t.Run(st.name, func(t *testing.T) {
			s, _ := newStore(t)
			seedVoice(t, s, "snakes", 20, words90())
			origWAV, _ := os.ReadFile(s.WAVPath("snakes"))
			origJSON, _ := os.ReadFile(s.metaPath("snakes"))
			tr := fixedWords(speechWords(60, 0.3, 0.1, 6), new(int))
			s.SetTranscriber(tr)
			s.rename = func(o, n string) error {
				if st.fail(o, n) {
					return errors.New("simulated crash")
				}
				return os.Rename(o, n)
			}
			r, err := s.PrepareRepair(context.Background(), "snakes")
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
			r2, err := s2.PrepareRepair(context.Background(), "snakes")
			if err != nil || r2 == nil {
				t.Fatalf("after the crash PrepareRepair = %v, %v; want a repair (the voice is still broken)", r2, err)
			}
			if err := r2.Apply(); err != nil {
				t.Fatal(err)
			}
			v, _ := s2.Get("snakes")
			if v.RefText == words90() || !strings.HasPrefix(v.RefText, "w0 w1") {
				t.Fatalf("ref_text after convergence = %q", v.RefText)
			}
			if d, _ := WAVSeconds(s2.WAVPath("snakes")); d > MaxRefSeconds || d < 10 {
				t.Fatalf("clip = %.2f s", d)
			}
			bw, _ := os.ReadFile(s2.backupPath("snakes", ".wav"))
			bj, _ := os.ReadFile(s2.backupPath("snakes", ".json"))
			if !bytes.Equal(bw, origWAV) || !bytes.Equal(bj, origJSON) {
				t.Fatal("the backup is not the byte-identical original pair")
			}
			// And now it is done: a further start does nothing.
			if r3, err := s2.PrepareRepair(context.Background(), "snakes"); r3 != nil || err != nil {
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
	seedVoice(t, s, "snakes", 20, words90())
	// a backup exists, main still has the original text (repair died after the marker)
	if err := os.WriteFile(s.backupPath("snakes", ".wav"), testutil.SilentWAV(20), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(s.backupPath("snakes", ".json"), []byte(`{"name":"snakes","ref_text":"`+words90()+`"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), new(int)))
	r, err := s.PrepareRepair(context.Background(), "snakes")
	if err != nil || r == nil || !r.Retry {
		t.Fatalf("PrepareRepair = %+v, %v; want a retry", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	if v, _ := s.Get("snakes"); v.RefText == words90() {
		t.Fatal("still broken after the retry")
	}
	if bj, _ := os.ReadFile(s.backupPath("snakes", ".json")); !strings.Contains(string(bj), words90()) {
		t.Fatal("backup json overwritten by the retry")
	}
}

func TestRemoveDeletesRepairBackup(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "snakes", 20, words90())
	for _, ext := range []string{".wav", ".json"} {
		if err := os.WriteFile(s.backupPath("snakes", ext), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Remove("snakes"); err != nil {
		t.Fatal(err)
	}
	left, _ := filepath.Glob(filepath.Join(s.dir, "snakes*"))
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
	seedVoice(t, s, "snakes", 20, words90())
	if _, err := s.PrepareRepair(context.Background(), "snakes"); !errors.Is(err, ErrNoTranscriber) {
		t.Fatalf("err = %v, want ErrNoTranscriber", err)
	}
	if v, _ := s.Get("snakes"); v.RefText != words90() {
		t.Fatal("voice modified without a transcriber")
	}
	if _, err := os.Stat(filepath.Join(s.dir, "snakes.orig.json")); err == nil {
		t.Fatal("backup written for a repair that did not happen")
	}
}

// A real at-cap voice whose text runs a few words past its audio must be
// repaired (the overall word ratio alone calls it healthy: 0.88).
// Mutation: internal/voices/repair.go plan — call TextsMatch instead of
// TranscriptMatches -> RED for deniro, william, daniel.
func TestRepairRealOverrunVoices(t *testing.T) {
	raw, err := os.ReadFile("testdata/real_voices.json")
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
	wantRepair := map[string]bool{"en-snakes": true, "en-geralt": true, "en-deniro": true, "en-william": true, "en-daniel": true}
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

// The backup .wav lands before the .json marker: a marker without its audio
// would claim a repair that cannot be retried from the backup.
// Mutation: internal/voices/repair.go Apply — iterate {".json", ".wav"} -> RED.
func TestRepairBackupOrderMarkerLast(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "snakes", 20, words90())
	var order []string
	s.rename = func(o, n string) error {
		if strings.Contains(filepath.Base(n), ".orig.") {
			order = append(order, filepath.Ext(n))
		}
		return os.Rename(o, n)
	}
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), new(int)))
	r, err := s.PrepareRepair(context.Background(), "snakes")
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	if len(order) != 2 || order[0] != ".wav" || order[1] != ".json" {
		t.Fatalf("backup rename order = %v, want [.wav .json]", order)
	}
}
