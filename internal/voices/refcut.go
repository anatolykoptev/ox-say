package voices

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode"
)

const (
	// MaxRefSeconds is the longest reference clip the engine conditions on.
	// tts-server caps the clip at 480000 samples (20 s at RefSampleRate) and
	// silently ignores the rest, so a transcript that covers more than this
	// describes audio the model never hears — the model then "continues" the
	// reference instead of speaking the request. Keep it in agreement with
	// the engine's cap.
	MaxRefSeconds = 20.0
	// RefSampleRate is the rate every stored clip is normalised to.
	RefSampleRate = 24000

	// probeSeconds is how much of an input clip Prepare normalises: one
	// second past the cap, enough to tell "fits" from "longer than the cap"
	// without decoding an hour-long file.
	probeSeconds = MaxRefSeconds + 1

	// capEpsilon absorbs container rounding when comparing a duration with
	// the cap: a clip within it of the cap is treated as capped.
	capEpsilon = 0.05

	// minPauseSeconds is the inter-word gap that counts as a phrase boundary
	// when choosing where to cut.
	minPauseSeconds = 0.3
	// cutTailSeconds is the audio kept after the last kept word's end so the
	// word does not end on a hard edge.
	cutTailSeconds = 0.15
	// sentencePauseSeconds is the pause that counts as a sentence end even
	// without punctuation.
	sentencePauseSeconds = 0.5
	// dataEndSlackSeconds is how close to the limit the last transcript word
	// must end for the transcript to count as truncated by the limit.
	dataEndSlackSeconds = 0.5
	// preferKeepSeconds is the length a boundary-preferring cut aims to keep
	// (60% of the cap): a sentence end at 9 s of a 20 s clip would throw away
	// the later, still-usable audio (en-william cut at 9 s still bled "…, but";
	// at its clause end 17.8 s, 4 of 4 runs were clean). Only when no boundary
	// exists that late does the cut fall back to minKeepSeconds.
	preferKeepSeconds = 12.0
	// minKeepSeconds is the least audio a boundary-preferring cut keeps: a
	// reference shorter than this conditions the voice poorly.
	minKeepSeconds = 6.0

	// MaxPlausibleWordsPerSecond is the ceiling above which a transcript
	// stored with a clip shorter than the cap cannot belong to it. Read speech
	// runs ~2-3.5 words/s in English (160-210 wpm) and Russian (longer words,
	// so fewer per second); fast conversational speakers reach ~4.2 (a real
	// 12.98 s / 53-word reference measured 4.1 and is correct), and nobody
	// sustains 4.5+. Clips AT the cap are caught by their duration instead, so
	// this only has to flag an obviously over-long transcript on a short clip.
	MaxPlausibleWordsPerSecond = 4.5

	// maxSpeechGapSeconds is the longest silence the kept words may contain
	// (including before the first word) before the transcript is not trusted:
	// the STT can drop whole stretches of speech, and a transcript that skips
	// audio is as mismatched as one that runs past it. Natural pauses in a
	// reference clip are well under this.
	maxSpeechGapSeconds = 5.0

	wavHeaderMin = 12         // RIFF + size + WAVE
	wavFmtMin    = 16         // PCM fmt chunk body
	wavUnsized   = 0xFFFFFFFF // data size of a streamed (unfinished) header
	chunkHeader  = 8
	chunkAlign   = 2
)

// Word is one timed word of a transcript, in seconds from the clip start.
type Word struct {
	W string
	S float64
	E float64
}

// Transcriber turns the WAV at path into timed words. The daemon wires its
// STT; a nil Transcriber means "cannot transcribe".
type Transcriber func(ctx context.Context, wavPath string) ([]Word, error)

// Cut is where a reference clip ends and the transcript that covers exactly
// the audio before it.
type Cut struct {
	At   float64 // seconds; the clip is kept in [0, At)
	Text string  // words up to At, space-joined
	Last int     // index of the last kept word
}

// PlanCut chooses the cut for a clip that runs past limit seconds. It keeps
// every word that ends at or before limit. A reference that stops mid-sentence
// invites the model to carry on, so the cut prefers, in order: the latest
// sentence end (terminal punctuation, or a pause of at least
// sentencePauseSeconds) at minKeepSeconds or later; the latest clause end
// (comma, semicolon, colon); the latest pause of at least minPauseSeconds;
// the last word. A short
// tail follows the word, at most half the gap to the next word so it never
// reaches into it (STT word times are quantised to ~80 ms). ok is false when
// no word ends within limit.
func PlanCut(words []Word, limit float64) (Cut, bool) {
	last := -1
	for i, w := range words {
		if w.E <= limit {
			last = i
		}
	}
	if last < 0 {
		return Cut{}, false
	}
	// When the transcript runs to the very end of a clip cut at the limit,
	// its last word is where the DATA ends, not a boundary: a reference that
	// stops there makes the model replay that word ("...things happening."
	// -> "happening, Oxay is ready", 2 of 3 runs on en-william). Boundaries
	// are then sought before it.
	hi := last
	if last == len(words)-1 && words[last].E >= limit-dataEndSlackSeconds {
		hi = last - 1
	}
	pick := -1
	for _, keep := range []float64{preferKeepSeconds, minKeepSeconds} {
		for _, boundary := range []func([]Word, int) bool{isSentenceEnd, isClauseEnd, isPause} {
			if pick = latest(words, hi, keep, boundary); pick >= 0 {
				break
			}
		}
		if pick >= 0 {
			break
		}
	}
	if pick < 0 {
		pick = last
	}
	// No next word means the transcript ends here, but the audio may run on:
	// at the cap, the onset of a word the STT did not complete. Keep no tail
	// there rather than carry that onset into the reference.
	tail := 0.0
	if pick+1 < len(words) {
		tail = max(0, min(cutTailSeconds, (words[pick+1].S-words[pick].E)/2))
	}
	return Cut{At: min(words[pick].E+tail, limit), Text: joinWords(words[:pick+1]), Last: pick}, true
}

// isPause reports a pause of at least minPauseSeconds after words[i].
func isPause(words []Word, i int) bool { return gapAfter(words, i) >= minPauseSeconds }

// latest returns the highest index <= last whose word ends at keep seconds
// or later and satisfies ok, or -1.
func latest(words []Word, last int, keep float64, ok func([]Word, int) bool) int {
	for i := last; i >= 0 && words[i].E >= keep; i-- {
		if ok(words, i) {
			return i
		}
	}
	return -1
}

// gapAfter is the silence between words[i] and the next word; 0 for the last.
func gapAfter(words []Word, i int) float64 {
	if i+1 >= len(words) {
		return 0
	}
	return words[i+1].S - words[i].E
}

// Covers reports whether words[:c.Last+1] account for the audio from the clip
// start to c.At: no leading or inner silence longer than maxSpeechGapSeconds.
func (c Cut) Covers(words []Word) bool {
	prev := 0.0
	for _, w := range words[:c.Last+1] {
		if w.S-prev > maxSpeechGapSeconds {
			return false
		}
		prev = max(prev, w.E)
	}
	return true
}

// isClauseEnd reports a comma, semicolon or colon on words[i].
func isClauseEnd(words []Word, i int) bool {
	t := []rune(strings.TrimSpace(words[i].W))
	return len(t) > 0 && strings.ContainsRune(",;:", t[len(t)-1])
}

// isSentenceEnd reports terminal punctuation on words[i] or a pause of at
// least sentencePauseSeconds after it.
func isSentenceEnd(words []Word, i int) bool {
	t := []rune(strings.TrimSpace(words[i].W))
	if len(t) > 0 && strings.ContainsRune(".!?…", t[len(t)-1]) {
		return true
	}
	return gapAfter(words, i) >= sentencePauseSeconds
}

func joinWords(words []Word) string {
	parts := make([]string, 0, len(words))
	for _, w := range words {
		if t := strings.TrimSpace(w.W); t != "" {
			parts = append(parts, t)
		}
	}
	return strings.Join(parts, " ")
}

// WordsPerSecond is the speaking rate a transcript implies for dur seconds.
func WordsPerSecond(text string, dur float64) float64 {
	if dur <= 0 {
		return 0
	}
	n := len(strings.FieldsFunc(text, unicode.IsSpace))
	return float64(n) / dur
}

// WAVSeconds returns the duration of a PCM WAV file by its fmt/data chunks.
func WAVSeconds(path string) (float64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return 0, err
	}
	hdr := make([]byte, wavHeaderMin)
	if _, err := io.ReadFull(f, hdr); err != nil || string(hdr[:4]) != "RIFF" || string(hdr[8:12]) != "WAVE" {
		return 0, fmt.Errorf("voices: %s is not a WAV file", path)
	}
	var bytesPerSec float64
	for {
		ch := make([]byte, chunkHeader)
		if _, err := io.ReadFull(f, ch); err != nil {
			return 0, fmt.Errorf("voices: %s has no data chunk", path)
		}
		size := int64(binary.LittleEndian.Uint32(ch[4:]))
		switch string(ch[:4]) {
		case "fmt ":
			body := make([]byte, size)
			if _, err := io.ReadFull(f, body); err != nil || size < wavFmtMin {
				return 0, fmt.Errorf("voices: %s has a bad fmt chunk", path)
			}
			rate := float64(binary.LittleEndian.Uint32(body[4:]))
			bytesPerSec = rate * float64(binary.LittleEndian.Uint16(body[2:])) * float64(binary.LittleEndian.Uint16(body[14:])) / 8
		case "data":
			pos, _ := f.Seek(0, io.SeekCurrent)
			if rest := st.Size() - pos; size > rest || size == wavUnsized {
				size = rest // streamed header or truncated file
			}
			if bytesPerSec <= 0 {
				return 0, fmt.Errorf("voices: %s: data before fmt", path)
			}
			return float64(size) / bytesPerSec, nil
		default:
			if _, err := f.Seek(size+size%chunkAlign, io.SeekCurrent); err != nil {
				return 0, err
			}
		}
	}
}
