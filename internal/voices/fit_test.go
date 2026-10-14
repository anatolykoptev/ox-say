package voices

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// speechWords is a synthetic transcript: n words, wordLen seconds each with a
// gap after every word; every sentenceEvery-th word ends a sentence.
func speechWords(n int, wordLen, gap float64, sentenceEvery int) []Word {
	out := make([]Word, n)
	t := 0.0
	for i := range out {
		w := fmt.Sprintf("w%d", i)
		if sentenceEvery > 0 && (i+1)%sentenceEvery == 0 {
			w += "."
		}
		out[i] = Word{W: w, S: t, E: t + wordLen}
		t += wordLen + gap
	}
	return out
}

func newStore(t *testing.T) (*Store, string) {
	t.Helper()
	dir := t.TempDir()
	s, err := New(filepath.Join(dir, "voices"))
	if err != nil {
		t.Fatal(err)
	}
	return s, dir
}

func fixedWords(words []Word, calls *int) Transcriber {
	return func(_ context.Context, _ string) ([]Word, error) {
		*calls++
		return words, nil
	}
}

// A clip past the cap with a ref_text is cut at a word end and ref_text
// becomes the transcript of the kept part.
// Mutation: internal/voices/fit.go fitReference — return `refText, "", nil`
// before the cap check (store the full clip, keep the caller's text) -> RED.
func TestPrepareLongClipCutsAtWordAndReplacesRefText(t *testing.T) {
	s, dir := newStore(t)
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
	words := speechWords(80, 0.3, 0.1, 7) // 0.4 s/word -> 32 s of "speech"
	calls := 0
	s.SetTranscriber(fixedWords(words, &calls))
	longText := strings.Repeat("the caller's transcript of the whole thirty seconds ", 20)

	v, err := s.Add(context.Background(), "ben", src, longText)
	if err != nil {
		t.Fatal(err)
	}
	dur, err := WAVSeconds(s.WAVPath("ben"))
	if err != nil {
		t.Fatal(err)
	}
	if dur > MaxRefSeconds+0.01 {
		t.Fatalf("stored clip is %.2f s, want <= %.0f", dur, MaxRefSeconds)
	}
	got := strings.Fields(v.RefText)
	if len(got) == 0 || got[0] != "w0" {
		t.Fatalf("ref_text = %q, want the transcript words", v.RefText)
	}
	last := len(got) - 1
	if want := fmt.Sprintf("w%d", last); !strings.HasPrefix(got[last], want) {
		t.Fatalf("ref_text words are not a contiguous prefix: last = %q", got[last])
	}
	if words[last].E > dur+1e-6 || words[last].E > MaxRefSeconds {
		t.Fatalf("last kept word ends at %.2f but the clip is %.2f s", words[last].E, dur)
	}
	if last+1 < len(words) && dur > words[last+1].S+0.01 {
		t.Fatalf("clip (%.2f s) runs into the next word starting at %.2f", dur, words[last+1].S)
	}
	if strings.Contains(v.RefText, "caller") {
		t.Fatalf("caller's ref_text survived: %q", v.RefText)
	}
	if v.Notice == "" {
		t.Fatal("no notice for a replaced ref_text")
	}
	stored, err := s.Get("ben")
	if err != nil || stored.RefText != v.RefText {
		t.Fatalf("stored ref_text = %q (%v), want %q", stored.RefText, err, v.RefText)
	}
	if calls != 1 {
		t.Fatalf("transcriber called %d times, want 1", calls)
	}
}

// The transcriber sees at most cap+1 s: Prepare must not decode the whole input.
func TestPrepareTranscribesOnlyTheProbeWindow(t *testing.T) {
	s, dir := newStore(t)
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 40)
	var seen float64
	s.SetTranscriber(func(_ context.Context, p string) ([]Word, error) {
		seen, _ = WAVSeconds(p)
		return speechWords(60, 0.3, 0.1, 5), nil
	})
	if _, err := s.Add(context.Background(), "ben", src, "x y z"); err != nil {
		t.Fatal(err)
	}
	if math.Abs(seen-probeSeconds) > 0.05 {
		t.Fatalf("transcriber got a %.2f s clip, want %.0f s", seen, probeSeconds)
	}
}

// Today's behaviour for a clip that fits: ref_text untouched, no STT.
func TestPrepareShortClipUnchanged(t *testing.T) {
	s, dir := newStore(t)
	src := testutil.WriteSilentWAV(t, dir, "short.wav", 12)
	calls := 0
	s.SetTranscriber(fixedWords(speechWords(30, 0.3, 0.1, 5), &calls))
	v, err := s.Add(context.Background(), "ben", src, "exactly what I typed")
	if err != nil {
		t.Fatal(err)
	}
	if v.RefText != "exactly what I typed" || v.Notice != "" {
		t.Fatalf("voice = %+v, want unchanged ref_text and no notice", v)
	}
	if calls != 0 {
		t.Fatalf("transcriber called %d times for a clip that fits", calls)
	}
	if d, _ := WAVSeconds(s.WAVPath("ben")); math.Abs(d-12) > 0.05 {
		t.Fatalf("stored clip is %.2f s, want 12", d)
	}
}

// Without STT a too-long clip with a ref_text is refused and nothing is stored.
// Mutation: internal/voices/fit.go fitReference — drop the `s.transcribe == nil`
// refusal and fall through with the caller's text -> RED.
func TestPrepareLongClipWithoutSTTRefused(t *testing.T) {
	cases := map[string]Transcriber{
		"nil": nil,
		"no model": func(context.Context, string) ([]Word, error) {
			return nil, fmt.Errorf("%w: model missing", ErrNoTranscriber)
		},
		"no speech": func(context.Context, string) ([]Word, error) { return nil, nil },
	}
	for name, tr := range cases {
		t.Run(name, func(t *testing.T) {
			s, dir := newStore(t)
			src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
			s.SetTranscriber(tr)
			_, err := s.Add(context.Background(), "ben", src, "some transcript")
			var ie *InputError
			if !errors.As(err, &ie) {
				t.Fatalf("err = %v, want *InputError", err)
			}
			if !strings.Contains(err.Error(), "20 s") {
				t.Fatalf("error does not name the limit: %v", err)
			}
			left, _ := os.ReadDir(filepath.Join(dir, "voices"))
			if len(left) != 0 {
				t.Fatalf("store dir not empty after a refusal: %v", left)
			}
		})
	}
}

// No ref_text: nothing to mismatch, the clip is cut at the cap as before and
// no transcription is spent.
func TestPrepareLongClipWithoutRefTextCutAtCap(t *testing.T) {
	s, dir := newStore(t)
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
	calls := 0
	s.SetTranscriber(fixedWords(nil, &calls))
	v, err := s.Add(context.Background(), "ben", src, "")
	if err != nil {
		t.Fatal(err)
	}
	if v.RefText != "" || calls != 0 {
		t.Fatalf("ref_text = %q, transcriber calls = %d", v.RefText, calls)
	}
	if d, _ := WAVSeconds(s.WAVPath("ben")); math.Abs(d-MaxRefSeconds) > 0.05 {
		t.Fatalf("stored clip is %.2f s, want %.0f", d, MaxRefSeconds)
	}
}

func TestPlanCut(t *testing.T) {
	tests := []struct {
		name     string
		words    []Word
		wantLast int
		wantAt   float64
		wantOK   bool
	}{
		{
			name:     "plain: last word within the cap; no gap, so no tail",
			words:    speechWords(100, 0.3, 0.0, 0),
			wantLast: 65, // ends at 19.8
			wantAt:   19.8,
			wantOK:   true,
		},
		{
			name: "sentence end in the last third wins over a later mid-sentence word",
			words: func() []Word {
				w := speechWords(100, 0.3, 0.0, 0)
				w[55].W = "end." // ends at 16.8
				return w
			}(),
			wantLast: 55,
			wantAt:   16.8,
			wantOK:   true,
		},
		{
			name: "pause >= 0.3 s in the last third wins",
			words: func() []Word {
				w := speechWords(100, 0.3, 0.0, 0)
				for i := 60; i < len(w); i++ { // 0.4 s gap after word 59
					w[i].S += 0.4
					w[i].E += 0.4
				}
				return w
			}(),
			wantLast: 59, // ends at 18.0
			wantAt:   18.15,
			wantOK:   true,
		},
		{
			name: "sentence end before minKeepSeconds is ignored",
			words: func() []Word {
				w := speechWords(100, 0.3, 0.0, 0)
				w[10].W = "early." // ends at 3.3 s
				return w
			}(),
			wantLast: 65,
			wantAt:   19.8,
			wantOK:   true,
		},
		{
			name:     "tail is 0.15 s when the gap is larger (and a 0.6 s pause is a sentence end)",
			words:    []Word{{W: "a", S: 0, E: 10}, {W: "b", S: 10.4, E: 19.5}, {W: "c", S: 20.1, E: 21}},
			wantLast: 1,
			wantAt:   19.65,
			wantOK:   true,
		},
		{
			name: "tail never reaches the next word",
			words: []Word{
				{W: "a", S: 0, E: 19.9},
				{W: "b", S: 19.95, E: 20.5},
			},
			wantLast: 0,
			wantAt:   19.925, // half the 0.05 s gap: STT times are quantised
			wantOK:   true,
		},
		{
			name: "the latest sentence end beats a later short pause and a later word",
			words: func() []Word {
				w := speechWords(100, 0.3, 0.0, 0)
				w[40].W = "stop." // ends 12.3
				w[50].W = "pause" // 0.4 s pause after (not a sentence end)
				for i := 51; i < len(w); i++ {
					w[i].S += 0.4
					w[i].E += 0.4
				}
				return w
			}(),
			wantLast: 40,
			wantAt:   12.3,
			wantOK:   true,
		},
		{
			name: "no sentence end: the latest pause of >= 0.3 s",
			words: func() []Word {
				w := speechWords(100, 0.3, 0.0, 0)
				for i := 50; i < len(w); i++ { // 0.35 s gap after word 49 (ends 15.0)
					w[i].S += 0.35
					w[i].E += 0.35
				}
				return w
			}(),
			wantLast: 49,
			wantAt:   15.15,
			wantOK:   true,
		},
		{
			name: "a transcript cut off at the limit does not end on its last word",
			words: func() []Word {
				w := speechWords(70, 0.28, 0.0, 0) // runs to ~19.6 s: the data end
				w[60].W = "club,"                  // a clause end at 17.08 s
				w[69].W = "happening."             // sentence end, but it IS the data end
				return w
			}(),
			wantLast: 60,
			wantAt:   17.08,
			wantOK:   true,
		},
		{
			name:   "nothing ends within the cap",
			words:  []Word{{W: "a", S: 0, E: 25}},
			wantOK: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, ok := PlanCut(tt.words, MaxRefSeconds)
			if ok != tt.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOK)
			}
			if !ok {
				return
			}
			if c.Last != tt.wantLast || math.Abs(c.At-tt.wantAt) > 1e-6 {
				t.Fatalf("cut = {last %d at %.3f}, want {last %d at %.3f}", c.Last, c.At, tt.wantLast, tt.wantAt)
			}
			if got := len(strings.Fields(c.Text)); got != tt.wantLast+1 {
				t.Fatalf("text has %d words, want %d", got, tt.wantLast+1)
			}
		})
	}
}

// An STT that skips stretches of the clip must not yield a stored pair: the
// transcript would describe less than the audio holds.
// Mutation: internal/voices/fit.go fitReference — delete the `!cut.Covers(words)`
// refusal -> RED.
func TestPrepareLongClipRefusesTranscriptThatSkipsAudio(t *testing.T) {
	s, dir := newStore(t)
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
	late := speechWords(10, 0.3, 0.1, 5)
	for i := range late { // speech only from 15.5 s on, as the real STT did
		late[i].S += 15.5
		late[i].E += 15.5
	}
	s.SetTranscriber(fixedWords(late, new(int)))
	_, err := s.Add(context.Background(), "ben", src, "whatever")
	var ie *InputError
	if !errors.As(err, &ie) {
		t.Fatalf("err = %v, want *InputError", err)
	}
	if _, err := s.Get("ben"); err == nil {
		t.Fatal("voice stored from a transcript that skips the first 15 s")
	}
}

func TestPrepareLongClipTransientSTTFailureIsNotInput(t *testing.T) {
	s, dir := newStore(t)
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
	s.SetTranscriber(func(context.Context, string) ([]Word, error) { return nil, errors.New("stt: busy") })
	_, err := s.Add(context.Background(), "ben", src, "some transcript")
	var ie *InputError
	if err == nil || errors.As(err, &ie) {
		t.Fatalf("err = %v, want a non-input error for a transient STT failure", err)
	}
	if !strings.Contains(err.Error(), "speech-to-text failed") {
		t.Fatalf("message does not say what failed: %v", err)
	}
}

// The STT cannot reproduce CJK/Arabic: the user's ref_text must survive as is,
// so a too-long clip is refused with the advice to trim it.
// Mutation: internal/voices/fit.go fitReference — delete the
// `Script(refText) == ""` refusal -> RED.
func TestPrepareLongClipNonLatinRefTextRefused(t *testing.T) {
	for name, text := range map[string]string{
		"cjk":    "今天天气很好，我们一起去公园玩，然后回家吃饭。",
		"arabic": "الطقس جميل اليوم وسوف نذهب إلى الحديقة معا",
	} {
		t.Run(name, func(t *testing.T) {
			s, dir := newStore(t)
			src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
			calls := 0
			s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), &calls))
			_, err := s.Add(context.Background(), "ben", src, text)
			var ie *InputError
			if !errors.As(err, &ie) || !strings.Contains(err.Error(), "trim the clip to at most 20 s") {
				t.Fatalf("err = %v, want an InputError that says to trim the clip", err)
			}
			if calls != 0 {
				t.Fatalf("STT called %d times for an untranscribable script", calls)
			}
			if _, err := s.Get("ben"); err == nil {
				t.Fatal("voice stored")
			}
		})
	}
}

// A Cyrillic ref_text whose STT transcript comes back in Latin (a language the
// STT did not recognise) is not replaced.
func TestPrepareLongClipScriptMismatchRefused(t *testing.T) {
	s, dir := newStore(t)
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
	s.SetTranscriber(fixedWords(speechWords(60, 0.3, 0.1, 6), new(int))) // "w0 w1…": Latin
	_, err := s.Add(context.Background(), "ben", src, "Добрый вечер это проверка голоса")
	var ie *InputError
	if !errors.As(err, &ie) {
		t.Fatalf("err = %v, want *InputError", err)
	}
}

func TestScriptAndMatch(t *testing.T) {
	for text, want := range map[string]string{
		"Hello there, world.":           scriptLatin,
		"Добрый вечер, это проверка.":   scriptCyrillic,
		"Добрый вечер, это проверка ok": scriptCyrillic,
		"今天天气很好":                        "",
		"الطقس جميل":                    "",
		"12345 !!!":                     "",
		"":                              "",
	} {
		if got := Script(text); got != want {
			t.Errorf("Script(%q) = %q, want %q", text, got, want)
		}
	}
	if !TextsMatch("Um, you create this pool of light.", "um you create this pool of light") {
		t.Error("punctuation and case must not matter")
	}
	if TextsMatch(strings.Repeat("word ", 90), strings.Repeat("word ", 45)) {
		t.Error("a transcript twice as long as the audio's matched")
	}
}

// Greek is one of parakeet-tdt-0.6b-v3's languages (el), so a Greek ref_text
// is transcribable and must not be refused as an unsupported script.
func TestScriptGreek(t *testing.T) {
	if got := Script("Καλησπέρα, αυτός είναι ένας έλεγχος φωνής."); got != scriptGreek {
		t.Fatalf("Script(greek) = %q", got)
	}
	if SameScript("Καλησπέρα κόσμε", "Hello world") {
		t.Fatal("greek and latin treated as the same script")
	}
}
