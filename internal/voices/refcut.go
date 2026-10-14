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
	// cutPreferWindow is the trailing share of the cap in which a sentence
	// end or pause is preferred over the very last word.
	cutPreferWindow = 1.0 / 3.0

	// MaxPlausibleWordsPerSecond is the ceiling above which a stored
	// transcript cannot belong to its clip. Read speech runs ~2-3.5 words/s
	// in both English (160-210 wpm) and Russian (longer words, so fewer per
	// second); audiobook narration peaks near 3.3. The measured broken
	// voices sit at 3.7-5.8 words/s (en-daniel, en-deniro, en-snakes,
	// en-geralt), healthy ones at 1.0-2.4.
	MaxPlausibleWordsPerSecond = 3.5

	wavHeaderMin = 12 // RIFF + size + WAVE
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
// every word that ends at or before limit, prefers the latest sentence end or
// pause of at least minPauseSeconds inside the last cutPreferWindow of limit,
// and adds a short tail that never reaches the next word. ok is false when no
// word ends within limit.
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
	pick := last
	from := limit * (1 - cutPreferWindow)
	for i := last; i >= 0 && words[i].E >= from; i-- {
		if isBoundary(words, i) {
			pick = i
			break
		}
	}
	at := words[pick].E + cutTailSeconds
	if pick+1 < len(words) && words[pick+1].S < at {
		at = max(words[pick+1].S, words[pick].E)
	}
	return Cut{At: min(at, limit), Text: joinWords(words[:pick+1]), Last: pick}, true
}

// isBoundary reports a sentence end at words[i], or a pause after it.
func isBoundary(words []Word, i int) bool {
	t := strings.TrimSpace(words[i].W)
	if t != "" && strings.ContainsRune(".!?…", []rune(t)[len([]rune(t))-1]) {
		return true
	}
	return i+1 < len(words) && words[i+1].S-words[i].E >= minPauseSeconds
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
			if _, err := io.ReadFull(f, body); err != nil || size < 16 {
				return 0, fmt.Errorf("voices: %s has a bad fmt chunk", path)
			}
			rate := float64(binary.LittleEndian.Uint32(body[4:]))
			bytesPerSec = rate * float64(binary.LittleEndian.Uint16(body[2:])) * float64(binary.LittleEndian.Uint16(body[14:])) / 8
		case "data":
			pos, _ := f.Seek(0, io.SeekCurrent)
			if rest := st.Size() - pos; size > rest || size == 0xFFFFFFFF {
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
