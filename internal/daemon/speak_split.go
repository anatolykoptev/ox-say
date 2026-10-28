package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/pcm"
)

// qwenChunkChars is the longest text one qwen3-tts call is given. The engine
// stops at 2048 frames (164 s of audio) and, measured end to end, a take that
// long has already lost its tail: Russian texts of 2000 to 3000 chars and
// English texts past 3300 came back cut or garbled at the end while the engine
// reported success (engine/README.md, "Speech length"). 600 characters speak
// in 25 to 60 s at the slowest rate measured, a third of the cap, so a piece
// is never near it and the engine's frame budget (patch 0003) stays tight.
const qwenChunkChars = 600

// chunkPause is the silence put between the pieces of a split text — a
// sentence-final pause, so the join is not heard as a cut.
const chunkPause = 0.25

// engineRunawayType is the error type tts-server answers (engine patch 0003)
// when a take hit its frame budget without the talker ending it.
const engineRunawayType = "generation_runaway"

// runawayMessage is what the caller reads when a take ran away.
const runawayMessage = "the speech engine did not finish the text and was stopped (it kept generating past its length budget); try again, the same text usually works, or shorten it"

// ttsFaults is /status tts_faults: takes the engine failed to finish since the
// daemon started. Runaways are classified (the engine said why); StreamAborts
// are streams cut after the first byte went out — the engine's log says why.
type ttsFaults struct {
	Runaways     int64 `json:"runaways"`
	StreamAborts int64 `json:"stream_aborts"`
}

// isRunaway reports whether an engine error body is the frame-budget stop.
func isRunaway(body []byte) bool {
	var v struct {
		Error struct {
			Type string `json:"type"`
		} `json:"error"`
	}
	return json.Unmarshal(body, &v) == nil && v.Error.Type == engineRunawayType
}

// noteRunaway counts and logs a take the engine stopped at its frame budget.
func (d *Daemon) noteRunaway(route string, chars int) {
	d.runaways.Add(1)
	d.log.Warn("tts runaway: the engine hit its frame budget without ending the take",
		slog.String("route", route), slog.Int("chars", chars))
}

// splitSpeech cuts text into pieces of at most max characters at sentence
// boundaries (then clause, then word, then character boundaries only when a
// sentence alone is longer than max). Text that fits comes back whole and
// untouched. Pieces are trimmed; whitespace between them is dropped.
func splitSpeech(text string, max int) []string {
	if utf8.RuneCountInString(text) <= max {
		return []string{text}
	}
	var atoms []string
	for _, s := range sentences(text) {
		atoms = append(atoms, shrink(s, max, 0)...)
	}
	return pack(atoms, max)
}

// pack joins consecutive atoms (each at most max) into pieces of at most max.
func pack(atoms []string, max int) []string {
	var parts []string
	cur := ""
	for _, a := range atoms {
		switch {
		case cur == "":
			cur = a
		case utf8.RuneCountInString(cur)+1+utf8.RuneCountInString(a) <= max:
			cur += " " + a
		default:
			parts = append(parts, cur)
			cur = a
		}
	}
	if cur != "" {
		parts = append(parts, cur)
	}
	return parts
}

// sentences splits at . ! ? … (and their CJK forms) that end a word, with any
// closing quote or bracket, and at line breaks.
func sentences(text string) []string {
	var out []string
	var cur []rune
	flush := func() {
		if s := strings.TrimSpace(string(cur)); s != "" {
			out = append(out, s)
		}
		cur = cur[:0]
	}
	rs := []rune(text)
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		if r == '\n' {
			flush()
			continue
		}
		cur = append(cur, r)
		if !strings.ContainsRune(".!?…。！？", r) {
			continue
		}
		j := i + 1
		for j < len(rs) && strings.ContainsRune(`"'»”’)]`, rs[j]) {
			cur = append(cur, rs[j])
			j++
		}
		cjk := strings.ContainsRune("。！？", r)
		if j >= len(rs) || unicode.IsSpace(rs[j]) || cjk {
			flush()
		}
		i = j - 1
	}
	flush()
	return out
}

// cutLevels are where a sentence longer than the limit may be cut, in order of
// preference: after clause punctuation, then after a space.
var cutLevels = []func(rune) bool{
	func(r rune) bool { return strings.ContainsRune(",;:—–、，；：", r) },
	unicode.IsSpace,
}

// shrink cuts s into atoms of at most max characters, trying cutLevels[level]
// first, then the next, and finally — a word longer than max — plain
// character boundaries.
func shrink(s string, max, level int) []string {
	if utf8.RuneCountInString(s) <= max {
		return []string{s}
	}
	if level < len(cutLevels) {
		runs := runsAfter(s, cutLevels[level])
		if len(runs) < 2 {
			return shrink(s, max, level+1)
		}
		var atoms []string
		for _, run := range runs {
			atoms = append(atoms, shrink(run, max, level+1)...)
		}
		return pack(atoms, max)
	}
	rs := []rune(s)
	var out []string
	for len(rs) > max {
		out = append(out, string(rs[:max]))
		rs = rs[max:]
	}
	return append(out, string(rs))
}

// runsAfter splits s after every rune cut accepts; runs are trimmed, none empty.
func runsAfter(s string, cut func(rune) bool) []string {
	var runs []string
	rs := []rune(s)
	start := 0
	add := func(end int) {
		if run := strings.TrimSpace(string(rs[start:end])); run != "" {
			runs = append(runs, run)
		}
		start = end
	}
	for i, r := range rs {
		if cut(r) {
			add(i + 1)
		}
	}
	add(len(rs))
	return runs
}

// synthesizeQwenSplit renders body's input on the qwen engine. Text longer than
// qwenChunkChars is spoken piece by piece, all pieces on ONE seed (one voice)
// and joined with a short pause; any piece failing fails the whole take.
func (d *Daemon) synthesizeQwenSplit(ctx context.Context, body map[string]any) (*synthOut, error) {
	input, _ := body[fieldInput].(string)
	parts := splitSpeech(input, qwenChunkChars)
	if len(parts) == 1 {
		wav, err := d.synthesizeQwen(ctx, body)
		if err != nil {
			return nil, err
		}
		return &synthOut{WAV: wav, Model: "qwen3-tts", Seed: seedOf(body)}, nil
	}
	if seedOf(body) == nil {
		body[fieldSeed] = randomSeed()
	}
	var joined pcm.Clip
	for i, p := range parts {
		b := maps(body)
		b[fieldInput] = p
		wav, err := d.synthesizeQwen(ctx, b)
		if err != nil {
			return nil, fmt.Errorf("part %d of %d: %w", i+1, len(parts), err)
		}
		c, err := pcm.Decode(wav)
		if err != nil {
			return nil, fmt.Errorf("part %d of %d: engine audio: %w", i+1, len(parts), err)
		}
		if i == 0 {
			joined.Rate = c.Rate
		} else if c.Rate != joined.Rate {
			return nil, fmt.Errorf("part %d of %d: engine audio is %d Hz, part 1 was %d Hz", i+1, len(parts), c.Rate, joined.Rate)
		} else {
			joined.S = append(joined.S, pcm.Silence(c.Rate, chunkPause).S...)
		}
		joined.S = append(joined.S, c.S...)
	}
	return &synthOut{WAV: joined.Encode(), Model: "qwen3-tts", Seed: seedOf(body)}, nil
}

// recordingReader remembers the error its source returned, so a copy can tell
// an upstream failure from a client that went away.
type recordingReader struct {
	r   io.Reader
	err error
}

func (rr *recordingReader) Read(p []byte) (int, error) {
	n, err := rr.r.Read(p)
	if err != nil && err != io.EOF {
		rr.err = err
	}
	return n, err
}

// abortResponse breaks the connection under a response whose body already
// started, so the client sees a failed transfer and not a short audio that
// ends cleanly. The connection is hijacked and closed; the server's Recovery
// middleware turns a panic(http.ErrAbortHandler) into a 500 body appended to
// the audio, so that is only the fallback.
func abortResponse(w http.ResponseWriter) {
	if conn, _, err := http.NewResponseController(w).Hijack(); err == nil {
		_ = conn.Close()
		return
	}
	panic(http.ErrAbortHandler)
}
