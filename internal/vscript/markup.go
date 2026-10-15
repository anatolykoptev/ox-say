// Package vscript turns a voiceover script into the chunks one TTS request
// each speaks: paragraphs, two directives ([pause …], [style: …]), Russian
// sentence splitting and size-bounded grouping. Pure: no I/O.
package vscript

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	defaultMarkPause = 0.6
	minMarkPause     = 0.05
	maxMarkPause     = 10.0
	msPerSecond      = 1000.0
)

// Options sizes chunks and the silences between them.
type Options struct {
	TargetChars    int     // a chunk grows by whole sentences up to this many runes
	MaxChars       int     // a sentence longer than this is split at a clause
	MinChars       int     // a shorter last chunk of a paragraph joins its predecessor
	MaxScriptChars int     // the whole script
	ChunkPause     float64 // seconds between chunks of one paragraph
	ParagraphPause float64 // seconds between paragraphs
}

// Chunk is one engine request's worth of script.
type Chunk struct {
	Index      int
	Paragraph  int
	Text       string // as written: subtitles and the WER reference
	Spoken     string // what the engine reads
	Style      string // the paragraph's [style:], cleaned; "" = the job default
	PauseAfter float64
}

// LineError is a script mistake the user fixes at a line.
type LineError struct {
	Line int
	Msg  string
}

func (e *LineError) Error() string { return fmt.Sprintf("line %d: %s", e.Line, e.Msg) }

var (
	directiveRe = regexp.MustCompile(`\[([^\[\]\n]*)\]`)
	pauseRe     = regexp.MustCompile(`^pause(?:\s+([0-9]+(?:[.,][0-9]+)?)\s*(ms|s)?)?$`)
	styleRe     = regexp.MustCompile(`^style\s*:\s*(.*)$`)
)

type block struct {
	text string
	line int // 1-based line the paragraph starts on
}

type piece struct {
	text  string
	pause float64 // > 0: a [pause] item
}

// Parse splits src into chunks. A paragraph is a blank-line-separated block.
func Parse(src string, o Options) ([]Chunk, error) {
	if n := utf8.RuneCountInString(src); n > o.MaxScriptChars {
		return nil, &LineError{1, fmt.Sprintf("the script is %d characters; the limit is %d", n, o.MaxScriptChars)}
	}
	var out []Chunk
	pending := 0.0
	para := 0
	for _, b := range paragraphs(src) {
		style, body, err := leadingStyle(b)
		if err != nil {
			return nil, err
		}
		pieces, err := splitPauses(body, b.line)
		if err != nil {
			return nil, err
		}
		emitted := false
		for _, p := range pieces {
			if p.pause > 0 {
				pending += p.pause
				continue
			}
			for _, text := range chunkParagraph(Sentences(p.text), o) {
				if n := len(out); n > 0 {
					out[n-1].PauseAfter = gapBefore(o, emitted, pending)
				}
				pending = 0
				out = append(out, Chunk{Index: len(out), Paragraph: para, Text: text, Spoken: Spoken(text), Style: style})
				emitted = true
			}
		}
		if emitted {
			para++
		}
	}
	if len(out) == 0 {
		return nil, &LineError{1, "the script has no text to speak"}
	}
	return out, nil
}

// gapBefore: an explicit pause replaces the default; a chunk opening a
// paragraph gets the paragraph gap.
func gapBefore(o Options, samePara bool, pending float64) float64 {
	switch {
	case pending > 0:
		return min(pending, maxMarkPause)
	case samePara:
		return o.ChunkPause
	default:
		return o.ParagraphPause
	}
}

func paragraphs(src string) []block {
	var out []block
	var cur []string
	start := 0
	flush := func() {
		if t := strings.TrimSpace(strings.Join(cur, "\n")); t != "" {
			out = append(out, block{t, start})
		}
		cur = nil
	}
	for i, line := range strings.Split(strings.ReplaceAll(src, "\r\n", "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			flush()
			continue
		}
		if cur == nil {
			start = i + 1
		}
		cur = append(cur, line)
	}
	flush()
	return out
}

// leadingStyle takes a [style: …] that opens the paragraph.
func leadingStyle(b block) (style, body string, err error) {
	body = b.text
	m := directiveRe.FindStringSubmatchIndex(body)
	if m == nil || strings.TrimSpace(body[:m[0]]) != "" {
		return "", body, nil
	}
	sm := styleRe.FindStringSubmatch(strings.TrimSpace(body[m[2]:m[3]]))
	if sm == nil {
		return "", body, nil
	}
	style = CleanStyle(sm[1])
	switch {
	case style == "":
		return "", "", &LineError{b.line, "[style: …] needs a description, e.g. [style: calm and warm]"}
	case utf8.RuneCountInString(style) > MaxStyleChars:
		return "", "", &LineError{b.line, fmt.Sprintf("a style is at most %d characters", MaxStyleChars)}
	}
	body = strings.TrimSpace(body[m[1]:])
	if body == "" {
		return "", "", &LineError{b.line, "[style: …] must be followed by the paragraph it applies to"}
	}
	return style, body, nil
}

// splitPauses cuts a body at [pause …]; any other directive is an error.
func splitPauses(body string, firstLine int) ([]piece, error) {
	var out []piece
	last := 0
	for _, m := range directiveRe.FindAllStringSubmatchIndex(body, -1) {
		line := firstLine + strings.Count(body[:m[0]], "\n")
		inner := strings.ToLower(strings.TrimSpace(body[m[2]:m[3]]))
		pm := pauseRe.FindStringSubmatch(inner)
		if pm == nil {
			return nil, &LineError{line, fmt.Sprintf("unknown directive [%s]: use [pause 0.6s] anywhere, or [style: …] at the start of a paragraph", inner)}
		}
		secs, err := pauseSeconds(pm[1], pm[2])
		if err != nil {
			return nil, &LineError{line, err.Error()}
		}
		if t := strings.TrimSpace(body[last:m[0]]); t != "" {
			out = append(out, piece{text: t})
		}
		out = append(out, piece{pause: secs})
		last = m[1]
	}
	if t := strings.TrimSpace(body[last:]); t != "" {
		out = append(out, piece{text: t})
	}
	return out, nil
}

func pauseSeconds(num, unit string) (float64, error) {
	if num == "" {
		return defaultMarkPause, nil
	}
	v, err := strconv.ParseFloat(strings.ReplaceAll(num, ",", "."), 64)
	if err != nil {
		return 0, fmt.Errorf("pause %q is not a number", num)
	}
	if unit == "ms" {
		v /= msPerSecond
	}
	if v < minMarkPause || v > maxMarkPause {
		return 0, fmt.Errorf("a pause must be %.2f–%.0f s", minMarkPause, maxMarkPause)
	}
	return v, nil
}
