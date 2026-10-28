// Package vscript turns a voiceover script into the chunks one TTS request
// each speaks: paragraphs, two directives ([pause …], [style: …]), Russian
// sentence splitting and size-bounded grouping. Pure: no I/O.
package vscript

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	utf8BOM          = "\ufeff"
	defaultMarkPause = 0.6
	msPerSecond      = 1000.0
)

// MinPause and MaxPause bound a silence between chunks: the same range the
// [pause Ns] directive enforces and the delivery op reuses.
const (
	MinPause = 0.05
	MaxPause = 10.0
)

// Options sizes chunks and the silences between them.
type Options struct {
	TargetChars    int // a chunk grows by whole sentences up to this many runes
	MaxChars       int // a sentence longer than this is split at a clause
	MinChars       int // a shorter last chunk of a paragraph joins its predecessor
	MaxScriptChars int // the whole script
	MaxSpokenChars int // the engine's per-request cap on Chunk.Spoken, which numbers written as words make longer than Text; 0 = no cap
	// Language is the language the script is spoken in ("ru", "en"): only a
	// Russian script has its numbers written as Russian words. "" = decided
	// from the script given to Parse (ScriptLanguage).
	Language       string
	ChunkPause     float64 // seconds between chunks of one paragraph
	ParagraphPause float64 // seconds between paragraphs
}

// Chunk is one engine request's worth of script.
type Chunk struct {
	Index      int
	Paragraph  int
	Text       string // the chunk's sentences with white space collapsed to single spaces and directives removed: subtitles and the WER reference
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
	styleRe     = regexp.MustCompile(`(?i)^style\s*:\s*(.*)$`)
)

type block struct {
	text string
	line int // 1-based line the paragraph starts on
}

type piece struct {
	text  string
	pause float64 // > 0: a [pause] item
	line  int     // line the item starts on
}

// Parse splits src into chunks. A paragraph is a blank-line-separated block.
func Parse(src string, o Options) ([]Chunk, error) {
	if err := o.validate(); err != nil {
		return nil, err
	}
	src = strings.TrimPrefix(src, utf8BOM)
	if n := utf8.RuneCountInString(src); n > o.MaxScriptChars {
		return nil, &LineError{1, fmt.Sprintf("the script is %d characters; the limit is %d", n, o.MaxScriptChars)}
	}
	if o.Language == "" {
		o.Language = SpokenLanguage(src)
	}
	var out []Chunk
	pending := 0.0
	para := 0
	for _, b := range paragraphs(src) {
		style, body, bodyLine, err := leadingStyle(b)
		if err != nil {
			return nil, err
		}
		pieces, err := splitPauses(body, bodyLine)
		if err != nil {
			return nil, err
		}
		emitted := false
		for _, p := range pieces {
			if p.pause > 0 {
				if len(out) == 0 {
					return nil, &LineError{p.line, "a pause needs text before it"}
				}
				pending += p.pause
				continue
			}
			for _, fc := range fitSpoken(chunkParagraph(Sentences(p.text), o), o) {
				if n := len(out); n > 0 {
					out[n-1].PauseAfter = gapBefore(o, emitted, pending)
				}
				pending = 0
				out = append(out, Chunk{Index: len(out), Paragraph: para, Text: fc.text, Spoken: fc.spoken(o.Language), Style: style})
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
	if pending > 0 {
		out[len(out)-1].PauseAfter = min(pending, MaxPause)
	}
	return out, nil
}

// validate rejects sizes the chunker cannot honour: Min < Target <= Max.
func (o Options) validate() error {
	switch {
	case o.MinChars <= 0 || o.TargetChars <= o.MinChars || o.MaxChars < o.TargetChars:
		return fmt.Errorf("chunk sizes must satisfy 0 < min (%d) < target (%d) <= max (%d)", o.MinChars, o.TargetChars, o.MaxChars)
	case o.MaxScriptChars <= 0 || o.ChunkPause < 0 || o.ParagraphPause < 0:
		return errors.New("script limit must be positive and pauses must not be negative")
	}
	return nil
}

// gapBefore: an explicit pause replaces the default; a chunk opening a
// paragraph gets the paragraph gap.
func gapBefore(o Options, samePara bool, pending float64) float64 {
	switch {
	case pending > 0:
		return min(pending, MaxPause)
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

// leadingStyle takes a [style: …] that opens the paragraph. bodyLine is the
// line the returned body starts on.
func leadingStyle(b block) (style, body string, bodyLine int, err error) {
	body, bodyLine = b.text, b.line
	m := directiveRe.FindStringSubmatchIndex(body)
	if m == nil || strings.TrimSpace(body[:m[0]]) != "" {
		return "", body, bodyLine, nil
	}
	sm := styleRe.FindStringSubmatch(strings.TrimSpace(body[m[2]:m[3]]))
	if sm == nil {
		return "", body, bodyLine, nil
	}
	style = CleanStyle(sm[1])
	switch {
	case style == "":
		return "", "", 0, &LineError{b.line, "[style: …] needs a description, e.g. [style: calm and warm]"}
	case utf8.RuneCountInString(style) > MaxStyleChars:
		return "", "", 0, &LineError{b.line, fmt.Sprintf("a style is at most %d characters", MaxStyleChars)}
	}
	rest := body[m[1]:]
	body = strings.TrimSpace(rest)
	if body == "" {
		return "", "", 0, &LineError{b.line, "[style: …] must be followed by the paragraph it applies to"}
	}
	consumed := b.text[:m[1]] + rest[:len(rest)-len(strings.TrimLeftFunc(rest, unicode.IsSpace))]
	return style, body, b.line + strings.Count(consumed, "\n"), nil
}

// splitPauses cuts a body at [pause …]; any other directive is an error.
func splitPauses(body string, firstLine int) ([]piece, error) {
	var out []piece
	last := 0
	for _, m := range directiveRe.FindAllStringSubmatchIndex(body, -1) {
		line := firstLine + strings.Count(body[:m[0]], "\n")
		inner := strings.ToLower(strings.TrimSpace(body[m[2]:m[3]]))
		pm := pauseRe.FindStringSubmatch(inner)
		if pm == nil && styleRe.MatchString(inner) {
			return nil, &LineError{line, "[style: …] is only allowed at the start of a paragraph"}
		}
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
		out = append(out, piece{pause: secs, line: line})
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
	if v < MinPause || v > MaxPause {
		return 0, fmt.Errorf("a pause must be %.2f–%.0f s", MinPause, MaxPause)
	}
	return v, nil
}

// SpokenLanguage is ScriptLanguage of what is read aloud: the text of the
// pieces with [style:] and [pause] directives and leading "(cue)" groups left
// out, so a Russian cue word does not make an English script Russian. A script
// whose directives are malformed is judged on the whole text; Parse reports the
// error itself.
func SpokenLanguage(src string) string {
	var spoken strings.Builder
	for _, b := range paragraphs(src) {
		_, body, line, err := leadingStyle(b)
		if err != nil {
			return ScriptLanguage(src)
		}
		pieces, err := splitPauses(body, line)
		if err != nil {
			return ScriptLanguage(src)
		}
		for _, p := range pieces {
			if p.pause == 0 {
				spoken.WriteString(stripLeadingCues(p.text))
				spoken.WriteByte(' ')
			}
		}
	}
	return ScriptLanguage(spoken.String())
}

// stripLeadingCues drops the "(…)" groups a text opens with (the engine reads
// them as its style tag).
func stripLeadingCues(text string) string {
	for s := trimLead(text); strings.HasPrefix(s, "("); s = trimLead(text) {
		_, rest, closed := strings.Cut(s[1:], ")")
		if !closed {
			return text
		}
		text = rest
	}
	return text
}
