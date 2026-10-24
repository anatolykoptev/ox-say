package meeting

import (
	"encoding/binary"
	"fmt"
	"io"

	"github.com/anatolykoptev/ox-say/internal/pcm"
)

const (
	// DefaultPieceSeconds: a piece is about 240 s, under the resident STT server's
	// 300 s limit (stt.serverMaxAudio), so every piece takes the warm GPU
	// path, and short enough that a dictation never waits long behind one.
	// A CPU-only Mac decodes far slower than real time: the daemon asks for
	// shorter pieces there (Deps.PieceSeconds), because one transcription at
	// a time holds the recognizer for dictation too.
	DefaultPieceSeconds = 240
	// searchSamples: the cut between pieces is the quietest half second within
	// 12 s either side of the nominal cut, so it lands between words.
	searchSamples = 12 * SampleRate
	quietWindow   = SampleRate / 2
	// silentPeak: a piece whose loudest sample is below this (about -60 dBFS)
	// holds no speech and is not sent to the recognizer.
	silentPeak = 30
)

// Span is a run of samples [From, To) of one channel file.
type Span struct{ From, To int }

// Spans cuts a channel file of n bytes into pieces of about pieceSeconds at
// quiet points (0 means DefaultPieceSeconds). The file is raw signed 16-bit
// little-endian mono at SampleRate, with no header. A tail shorter than a
// quarter piece joins the piece before it.
func Spans(r io.ReaderAt, nBytes int64, pieceSeconds int) ([]Span, error) {
	if pieceSeconds <= 0 {
		pieceSeconds = DefaultPieceSeconds
	}
	pieceSamples := pieceSeconds * SampleRate
	minTail := pieceSamples / 4
	total := int(nBytes / bytesPerSample)
	if total == 0 {
		return nil, nil
	}
	var spans []Span
	from := 0
	for from+pieceSamples+minTail < total {
		nominal := from + pieceSamples
		lo := max(from+SampleRate, nominal-searchSamples)
		// The slice reaches one window past the zone: QuietestWindow's
		// candidates are whole windows, so a gap sitting in the last
		// part-window of a tightly sliced zone is never measured (issue #225).
		hi := min(total, nominal+searchSamples+quietWindow)
		clip, err := ReadClip(r, Span{lo, hi})
		if err != nil {
			return nil, err
		}
		cut := lo + clip.QuietestWindow(quietWindow) + quietWindow/2
		spans = append(spans, Span{from, cut})
		from = cut
	}
	return append(spans, Span{from, total}), nil
}

// ReadClip reads one span as a clip.
func ReadClip(r io.ReaderAt, s Span) (pcm.Clip, error) {
	buf := make([]byte, (s.To-s.From)*bytesPerSample)
	n, err := r.ReadAt(buf, int64(s.From)*bytesPerSample)
	if err != nil && !(err == io.EOF && n == len(buf)) {
		return pcm.Clip{}, fmt.Errorf("meeting: reading audio: %w", err)
	}
	c := pcm.Clip{Rate: SampleRate, S: make([]int16, len(buf)/bytesPerSample)}
	for i := range c.S {
		c.S[i] = int16(binary.LittleEndian.Uint16(buf[bytesPerSample*i:]))
	}
	return c, nil
}

// Silent reports a clip with no speech in it: nothing louder than silentPeak.
func Silent(c pcm.Clip) bool {
	for _, s := range c.S {
		if s > silentPeak || s < -silentPeak {
			return false
		}
	}
	return true
}
