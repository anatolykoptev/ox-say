package meeting

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/pcm"
)

// rawPCM builds a channel file of sec seconds of constant tone, with a
// half-second gap of digital silence at each second in gaps.
func rawPCM(sec int, gaps ...int) *bytes.Reader {
	s := make([]int16, sec*SampleRate)
	for i := range s {
		s[i] = 6000
	}
	for _, g := range gaps {
		for i := g * SampleRate; i < g*SampleRate+quietWindow && i < len(s); i++ {
			s[i] = 0
		}
	}
	var buf bytes.Buffer
	_ = binary.Write(&buf, binary.LittleEndian, s)
	return bytes.NewReader(buf.Bytes())
}

// The cut lands in the quiet gap near the nominal 240 s, not exactly on it.
// Mutation: internal/meeting/audio.go Spans, replace `cut := lo + ...` with
// `cut := nominal` -> RED (the cut is on the nominal sample, mid-word).
func TestSpansCutAtTheQuietGap(t *testing.T) {
	r := rawPCM(600, 236)
	spans, err := Spans(r, int64(r.Len()), 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) != 3 {
		t.Fatalf("spans = %v, want 3 pieces for 600 s", spans)
	}
	cut := spans[0].To
	if cut < 236*SampleRate || cut > 237*SampleRate {
		t.Fatalf("first cut at %.2f s, want inside the gap at 236 s", float64(cut)/SampleRate)
	}
	if spans[1].From != cut || spans[2].To != 600*SampleRate {
		t.Fatalf("spans must tile the file: %v", spans)
	}
}

// A quiet stretch at the very edge of the search zone must still be a
// candidate: QuietestWindow's candidates are whole windows starting at
// multiples of half a window, so a zone sliced at its exact end never sees a
// gap sitting in the last part-window (issue #225). The cut reads the zone
// with a full window of margin.
// Mutation: internal/meeting/audio.go Spans, drop `+ quietWindow` from the hi
// bound -> RED (the gap at 252 s falls outside the slice; the cut lands at
// the zone start, mid-tone).
func TestSpansFindsAGapAtTheZoneEdge(t *testing.T) {
	r := rawPCM(320, 252) // the gap starts exactly at the +12 s zone edge
	spans, err := Spans(r, int64(r.Len()), 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) != 2 {
		t.Fatalf("spans = %v, want 2 pieces for 320 s", spans)
	}
	cut := spans[0].To
	if cut < 252*SampleRate || cut > 253*SampleRate {
		t.Fatalf("cut at %.2f s, want inside the gap at 252 s", float64(cut)/SampleRate)
	}
}

func TestSpansShortFileIsOnePiece(t *testing.T) {
	r := rawPCM(100)
	spans, _ := Spans(r, int64(r.Len()), 0)
	if len(spans) != 1 || spans[0] != (Span{0, 100 * SampleRate}) {
		t.Fatalf("spans = %v", spans)
	}
	if got, _ := Spans(bytes.NewReader(nil), 0, 0); got != nil {
		t.Fatalf("an empty file has no pieces: %v", got)
	}
}

func TestSpansDoNotLeaveATinyTail(t *testing.T) {
	r := rawPCM(250) // 10 s past one piece: joins it
	spans, _ := Spans(r, int64(r.Len()), 0)
	if len(spans) != 1 {
		t.Fatalf("spans = %v, want the 10 s tail merged", spans)
	}
}

// A trailing odd byte (a write cut in half by a crash) is ignored.
func TestSpansIgnoreAHalfSample(t *testing.T) {
	r := rawPCM(10)
	data := append([]byte(nil), mustBytes(r)...)
	data = append(data, 0x7f)
	spans, err := Spans(bytes.NewReader(data), int64(len(data)), 0)
	if err != nil || len(spans) != 1 || spans[0].To != 10*SampleRate {
		t.Fatalf("spans = %v, %v", spans, err)
	}
}

func mustBytes(r *bytes.Reader) []byte {
	b := make([]byte, r.Len())
	_, _ = r.ReadAt(b, 0)
	return b
}

// burst puts n samples of amplitude amp (alternating sign, so RMS == amp) into a
// clip of total samples, starting at from.
func burst(total, from, n int, amp int16) pcm.Clip {
	c := pcm.Clip{Rate: SampleRate, S: make([]int16, total)}
	for i := from; i < from+n && i < total; i++ {
		c.S[i] = amp
		if i%2 == 1 {
			c.S[i] = -amp
		}
	}
	return c
}

// Silence is judged by RMS over 100 ms windows: a faint voice is speech, a
// click or a mic's noise floor is not.
// Mutation: internal/meeting/audio.go Silent, change `> silentRMS` to
// `> 32000` -> RED (a quiet voice counts as silence and is never transcribed);
// change `minLoudWindows  = 2` to `= 1` -> RED (one click is loud again);
// change `silentRMS       = 75` to `= 30` -> RED (the noise floor of 40 is loud).
func TestSilent(t *testing.T) {
	const sec = 10 * SampleRate
	if !Silent(pcm.Clip{Rate: SampleRate, S: make([]int16, sec)}) {
		t.Fatal("zeros are silent")
	}
	// a faint voice: half a second at 400 RMS (well above -60 dBFS), either polarity
	for _, v := range []int16{400, -400} {
		c := burst(sec, 3*SampleRate, SampleRate/2, v)
		if Silent(c) {
			t.Fatalf("a faint voice (%d) is not silence", v)
		}
	}
	// a single full-scale sample, and a 5 ms click at 20000: neither is a word
	for name, c := range map[string]pcm.Clip{
		"one sample":   burst(sec, 3*SampleRate+800, 1, 32767),
		"5 ms click":   burst(sec, 3*SampleRate+400, 80, 20000),
		"click at end": burst(sec, sec-3, 3, 32767),
	} {
		if !Silent(c) {
			t.Errorf("%s must not count as speech", name)
		}
	}
	// the noise floor of a quiet room mic: loud samples now and then, RMS 40
	noise := burst(sec, 0, sec, 40)
	noise.S[1234], noise.S[99999] = 90, -90
	if !Silent(noise) {
		t.Error("a noise floor of RMS 40 must be silence")
	}
	// a short clip is judged by the windows it has
	if Silent(burst(SampleRate/10, 0, SampleRate/10, 5000)) {
		t.Error("a clip of one loud window is speech")
	}
}

// A CPU-only Mac asks for short pieces, so one recognizer call never holds the
// recognizer (shared with dictation) for minutes.
// Mutation: internal/meeting/audio.go Spans, change `pieceSamples := pieceSeconds * SampleRate`
// to `DefaultPieceSeconds * SampleRate` -> RED (the 45 s request still yields 240 s pieces).
func TestSpansHonourAShorterPiece(t *testing.T) {
	r := rawPCM(200)
	spans, err := Spans(r, int64(r.Len()), 45)
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) < 4 {
		t.Fatalf("spans = %v, want 4+ pieces of about 45 s for 200 s", spans)
	}
	for _, sp := range spans[:len(spans)-1] {
		if got := sp.To - sp.From; got > 60*SampleRate {
			t.Fatalf("piece of %d s exceeds the 45 s request", got/SampleRate)
		}
	}
}
