package voices

import (
	"context"
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

func TestRepairLeavesHealthyAndRepairedAlone(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "native", 5.4, "one two three four five six seven eight nine ten eleven")
	seedVoice(t, s, "done", 20, words90())
	if err := os.WriteFile(s.backupPath("done", ".json"), []byte(`{"name":"done"}`), 0o644); err != nil {
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
	v, _ := s.Get("done")
	if v.RefText != words90() {
		t.Fatalf("already-repaired voice was modified: %q", v.RefText)
	}
}

func TestRepairNeverOverwritesBackup(t *testing.T) {
	s, _ := newStore(t)
	seedVoice(t, s, "snakes", 20, words90())
	if err := os.WriteFile(s.backupPath("snakes", ".wav"), []byte("precious"), 0o644); err != nil {
		t.Fatal(err)
	}
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), new(int)))
	r, err := s.PrepareRepair(context.Background(), "snakes")
	if err != nil || r == nil {
		t.Fatalf("PrepareRepair = %v, %v", r, err)
	}
	if err := r.Apply(); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(s.backupPath("snakes", ".wav")); string(b) != "precious" {
		t.Fatalf("existing backup overwritten: %q", b)
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
