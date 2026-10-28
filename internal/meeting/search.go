package meeting

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// Search limits. The scan is a plain read of the meetings' files, newest first, with no index: it stops once the
// answer is full.
const (
	MaxQueryRunes     = 200
	MaxSearchMeetings = 50
	MaxHitsPerMeeting = 5
	// snippetRunes is the size of the text around a match that a hit shows.
	snippetRunes = 120
	// maxSearchFileBytes bounds what one search reads from one file (about 50 hours of talk in transcript.json); a
	// larger file is skipped and counted (SearchResult.Skipped), not read whole.
	maxSearchFileBytes = 8 << 20
	snippetEllipsis    = "…"
)

// Why a query is refused; the texts are served as they are and never repeat the query.
var (
	ErrSearchEmpty   = errors.New("the search text is empty")
	ErrSearchTooLong = errors.New("the search text is longer than 200 characters")
)

// Fields a Hit can come from.
const (
	FieldTitle      = "title"
	FieldNotes      = "notes"
	FieldTranscript = "transcript"
)

// Hit is one place a search matched. Start (seconds into the recording) and Speaker (the name the transcript shows)
// are set on a transcript hit only.
type Hit struct {
	Field   string   `json:"field"`
	Snippet string   `json:"snippet"`
	Start   *float64 `json:"start,omitempty"`
	Speaker string   `json:"speaker,omitempty"`
}

// SearchMeeting is a meeting with its hits.
type SearchMeeting struct {
	ID      string `json:"id"`
	Title   string `json:"title,omitempty"`
	Started string `json:"started"`
	Status  Status `json:"status"`
	Hits    []Hit  `json:"hits"`
}

// SearchResult is the answer to a search: at most MaxSearchMeetings meetings, newest first.
type SearchResult struct {
	Meetings []SearchMeeting `json:"meetings"`
	// Truncated: more meetings matched than were returned.
	Truncated bool `json:"truncated,omitempty"`
	// Skipped counts the texts that could not be searched (unreadable, or over the size bound).
	Skipped int `json:"skipped,omitempty"`
}

// Search finds the meetings whose title, notes or transcript contain q: a substring match that ignores case and
// diacritics (see foldRune). A meeting that is still being recorded or processed is searched by its title only: its
// texts are being written or are about to be replaced. The query and the texts are never logged. ctx is checked
// between meetings: a cancelled search returns its error.
func (s *Store) Search(ctx context.Context, q string) (SearchResult, error) {
	q = strings.TrimSpace(q)
	if q == "" {
		return SearchResult{}, ErrSearchEmpty
	}
	if utf8.RuneCountInString(q) > MaxQueryRunes {
		return SearchResult{}, ErrSearchTooLong
	}
	needle := foldRunes(norm.NFC.String(q))
	list, err := s.List()
	if err != nil {
		return SearchResult{}, err
	}
	res := SearchResult{Meetings: []SearchMeeting{}}
	for _, m := range list {
		if err := ctx.Err(); err != nil { // the caller is gone: stop reading files
			return SearchResult{}, err
		}
		hits, skipped := s.searchMeeting(m, needle)
		res.Skipped += skipped
		if len(hits) == 0 {
			continue
		}
		if len(res.Meetings) == MaxSearchMeetings {
			res.Truncated = true
			break
		}
		res.Meetings = append(res.Meetings, SearchMeeting{
			ID: m.ID, Title: m.Title, Started: m.Started.Format("2006-01-02T15:04:05Z07:00"), Status: m.Status, Hits: hits,
		})
	}
	return res, nil
}

// searchMeeting is the hits in one meeting (title, notes, transcript, in that order, at most MaxHitsPerMeeting) and
// the number of texts it could not search.
func (s *Store) searchMeeting(m Manifest, needle []rune) (hits []Hit, skipped int) {
	if sn, ok := matchOnce(m.Title, needle); ok {
		hits = append(hits, Hit{Field: FieldTitle, Snippet: sn})
	}
	if !m.Status.Terminal() {
		return hits, 0
	}
	dir, err := s.Dir(m.ID)
	if err != nil {
		return hits, 0
	}
	if len(hits) < MaxHitsPerMeeting {
		notes, skip := readSearchText(filepath.Join(dir, NotesMD))
		skipped += btoi(skip)
		hits = append(hits, notesHits(notes, needle, MaxHitsPerMeeting-len(hits))...)
	}
	if len(hits) < MaxHitsPerMeeting {
		th, skip := transcriptHits(dir, m, needle, MaxHitsPerMeeting-len(hits))
		hits, skipped = append(hits, th...), skipped+btoi(skip)
	}
	return hits, skipped
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

// readSearchText reads one text file for a search. A file that is not there is no text and no skip; one that cannot
// be read, or is over maxSearchFileBytes, is skipped (true).
func readSearchText(path string) (text string, skipped bool) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", false
	}
	if err != nil {
		return "", true
	}
	defer func() { _ = f.Close() }()
	raw, err := io.ReadAll(io.LimitReader(f, maxSearchFileBytes+1))
	if err != nil || len(raw) > maxSearchFileBytes {
		return "", true
	}
	return string(raw), false
}

// isMarkdownHeading reports an ATX heading line: one to six "#" and a space. "#42 fix" is text.
func isMarkdownHeading(line string) bool {
	n := 0
	for n < len(line) && line[n] == '#' {
		n++
	}
	return n >= 1 && n <= 6 && n < len(line) && line[n] == ' '
}

// stripMarkdown is notes.md text as a reader sees it, without the syntax: the block markers at a line start (quote,
// list item "- " "* " "+ " "1. ", task box "[ ]" "[x]"), the inline markers (emphasis "*" and "_", strike "~~", code
// "`"), and the escapes the writer adds (unescapeMarkdown). The result is plain untrusted text: nothing here makes
// a link, so the app, which renders a snippet without links, has none to draw. An escaped marker ("\*") is a
// literal character and stays. "*" and "_" go only where they are emphasis (stripInline), so "2*3=6", "snake_case"
// and "a__b" keep every character.
func stripMarkdown(s string) string {
	var out strings.Builder
	var block []rune // the paragraph or list item being read: emphasis may span its lines
	flush := func() {
		out.WriteString(stripInline(block))
		block = block[:0]
	}
	for line := range strings.Lines(s) {
		rest, item := stripBlockMarker(line)
		switch {
		case strings.TrimSpace(rest) == "":
			flush()
			out.WriteString(rest)
		case item:
			flush()
			fallthrough
		default:
			block = append(block, []rune(rest)...)
		}
	}
	flush()
	return out.String()
}

// mdCell is one rune of a block, with what stripInline decided about it.
type mdCell struct {
	r    rune
	lit  bool // an escaped character: never a delimiter
	drop bool
}

// delimRun is a maximal run of one emphasis character, "*" or "_", and what CommonMark says it can do
// (https://spec.commonmark.org/0.31.2/#emphasis-and-strong-emphasis): left is how many of its characters are
// still unmatched.
type delimRun struct {
	start, n, left int
	ch             rune
	canOpen        bool
	canClose       bool
}

func isMDSpace(r rune) bool { return unicode.IsSpace(r) }

// isMDPunct is CommonMark's "Unicode punctuation" (0.31): the P and S categories, so an emoji or a currency sign
// next to a delimiter is punctuation, not a word. A combining mark (Mn) is neither: it stays part of its word.
func isMDPunct(r rune) bool { return unicode.IsPunct(r) || unicode.IsSymbol(r) }

// stripInline removes the inline syntax of one block. "~~" and "`" always go. A run of "*" or "_" goes only when
// it is matched emphasis: an opener (left-flanking) with a later closer (right-flanking) of the same character.
// A run inside a word is flanked both ways, so "_" there can neither open nor close ("snake_case", "a__b") and a
// lone "*" ("2*3=6") has no partner; both stay. A dunder name between "__" ("__init__") is an identifier far more
// often than strong emphasis, so it stays too.
func stripInline(rs []rune) string {
	cells := make([]mdCell, 0, len(rs))
	for i := 0; i < len(rs); i++ {
		switch r := rs[i]; {
		case r == '\\' && i+1 < len(rs) && rs[i+1] < utf8.RuneSelf && strings.IndexByte(unescapable, byte(rs[i+1])) >= 0:
			i++
			cells = append(cells, mdCell{r: rs[i], lit: true})
		case r == '`':
		case r == '~' && i+1 < len(rs) && rs[i+1] == '~':
			i++
		default:
			cells = append(cells, mdCell{r: r})
		}
	}
	stacks := map[rune][]*delimRun{'*': nil, '_': nil}
	for i := 0; i < len(cells); {
		c := cells[i]
		if c.lit || (c.r != '*' && c.r != '_') {
			i++
			continue
		}
		run := &delimRun{start: i, ch: c.r}
		for i < len(cells) && !cells[i].lit && cells[i].r == run.ch {
			i++
		}
		run.n = i - run.start
		run.left = run.n
		prev, next := ' ', ' ' // the block's edges count as whitespace
		if run.start > 0 {
			prev = cells[run.start-1].r
		}
		if i < len(cells) {
			next = cells[i].r
		}
		left := !isMDSpace(next) && (!isMDPunct(next) || isMDSpace(prev) || isMDPunct(prev))
		right := !isMDSpace(prev) && (!isMDPunct(prev) || isMDSpace(next) || isMDPunct(next))
		if run.ch == '*' {
			run.canOpen, run.canClose = left, right
		} else {
			run.canOpen = left && (!right || isMDPunct(prev))
			run.canClose = right && (!left || isMDPunct(next))
		}
		st := stacks[run.ch]
		for run.canClose && run.left > 0 && len(st) > 0 {
			op := st[len(st)-1]
			matchDelims(cells, op, run)
			if op.left == 0 {
				st = st[:len(st)-1]
			}
		}
		if run.canOpen && run.left > 0 {
			st = append(st, run)
		}
		stacks[run.ch] = st
	}
	var b strings.Builder
	for _, c := range cells {
		if !c.drop {
			b.WriteRune(c.r)
		}
	}
	return b.String()
}

// matchDelims pairs the innermost characters of opener op with the first of closer cl and drops them, unless the
// pair is a dunder name.
func matchDelims(cells []mdCell, op, cl *delimRun) {
	k := min(op.left, cl.left)
	inner := cells[op.start+op.left : cl.start+cl.n-cl.left]
	if !(k == 2 && op.ch == '_' && op.n == 2 && cl.n == 2 && isDunderName(inner)) {
		for x := 0; x < k; x++ {
			cells[op.start+op.left-1-x].drop = true
			cells[cl.start+cl.n-cl.left+x].drop = true
		}
	}
	op.left -= k
	cl.left -= k
}

// isDunderName reports the lowercase identifier between "__" and "__" in "__init__" or "__main__".
func isDunderName(cells []mdCell) bool {
	if len(cells) == 0 || cells[0].r == '_' || cells[len(cells)-1].r == '_' {
		return false
	}
	for _, c := range cells {
		if c.lit || !(c.r >= 'a' && c.r <= 'z' || c.r >= '0' && c.r <= '9' || c.r == '_') {
			return false
		}
	}
	return true
}

// stripBlockMarker drops the block syntax at the start of one line: leading blanks, quote marks, one list marker and a
// task box. "#42 fix" and "2026-10-20" are text, so a number needs its "." or ")" and a space to be a marker. item
// reports a list marker or task box: a new item, so emphasis does not run on from the line before.
func stripBlockMarker(line string) (rest string, item bool) {
	line = strings.TrimLeft(line, " \t")
	for strings.HasPrefix(line, ">") {
		line = strings.TrimLeft(line[1:], " \t")
	}
	switch {
	case len(line) >= 2 && strings.IndexByte("-+*", line[0]) >= 0 && line[1] == ' ':
		line, item = strings.TrimLeft(line[2:], " "), true
	default:
		i := 0
		for i < len(line) && line[i] >= '0' && line[i] <= '9' {
			i++
		}
		if i > 0 && i+1 < len(line) && (line[i] == '.' || line[i] == ')') && line[i+1] == ' ' {
			line, item = strings.TrimLeft(line[i+2:], " "), true
		}
	}
	for _, box := range []string{"[ ] ", "[x] ", "[X] "} {
		if rest, ok := strings.CutPrefix(line, box); ok {
			return rest, true
		}
	}
	return line, item
}

// notesHits finds the needle in notes.md, up to limit hits. The headings (the title line and the section names; see
// isMarkdownHeading) are not searched: a query for a section name would match every meeting. After
// a hit the search goes on past its snippet, so one paragraph is one hit.
func notesHits(notes string, needle []rune, limit int) []Hit {
	var body strings.Builder
	for line := range strings.Lines(notes) {
		if !isMarkdownHeading(line) {
			body.WriteString(line)
		}
	}
	// Stripped BEFORE the text is folded and searched: every index below (the match, the snippet window) then belongs
	// to the text the snippet shows, whatever the markers took out.
	text := norm.NFC.String(stripMarkdown(body.String()))
	orig := []rune(text)
	hay := foldRunes(text)
	var hits []Hit
	for from := 0; len(hits) < limit; {
		i := indexRunes(hay, needle, from)
		if i < 0 {
			break
		}
		start, end := snippetWindow(len(orig), i, len(needle))
		hits = append(hits, Hit{Field: FieldNotes, Snippet: snippet(orig, start, end)})
		from = max(end, i+len(needle))
	}
	return hits
}

// transcriptHits finds the needle in the turns as the transcript shows them (Present: speakers named, merged voices
// folded), one hit per turn, up to limit. skipped: the transcript exists and could not be read.
func transcriptHits(dir string, m Manifest, needle []rune, limit int) (hits []Hit, skipped bool) {
	raw, err := readTurnsMax(dir, maxSearchFileBytes) // the bound is on the read itself, not on a stat before it
	if errors.Is(err, ErrSpeakersBusy) {              // no transcript yet
		return nil, false
	}
	if err != nil { // unreadable, or over the bound
		return nil, true
	}
	st, err := LoadSpeakers(dir)
	if err != nil { // the names are lost, the words are not
		st = SpeakerState{Version: SpeakersVersion}
	}
	shown, turns := Present(m, st, raw)
	for _, t := range turns {
		if len(hits) == limit {
			break
		}
		if sn, ok := matchOnce(t.Text, needle); ok {
			start := t.S
			hits = append(hits, Hit{Field: FieldTranscript, Snippet: sn, Start: &start, Speaker: shown.Labels.turnLabel(t)})
		}
	}
	return hits, false
}

// matchOnce is the snippet around the first match of needle in text.
func matchOnce(text string, needle []rune) (string, bool) {
	text = norm.NFC.String(text) // a decomposed letter matches its precomposed form; the snippet shows the composed text
	hay := foldRunes(text)
	i := indexRunes(hay, needle, 0)
	if i < 0 {
		return "", false
	}
	start, end := snippetWindow(len(hay), i, len(needle))
	return snippet([]rune(text), start, end), true
}

// snippetWindow is the rune range [start, end) of about snippetRunes around a match of length n at i in a text of
// total runes: the match centred, moved back from the end of the text, or (a match longer than the window) cut.
func snippetWindow(total, i, n int) (start, end int) {
	if n >= snippetRunes {
		return i, i + snippetRunes
	}
	start = max(0, i-(snippetRunes-n)/2)
	end = min(total, start+snippetRunes)
	return max(0, end-snippetRunes), end
}

// snippet is orig[start:end] as one display line: control characters and runs of white space become one space, and
// an ellipsis marks each end that is cut. It slices the rune slice, so it never cuts a character.
func snippet(orig []rune, start, end int) string {
	line := strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, string(orig[start:end]))), " ")
	if start > 0 {
		line = snippetEllipsis + line
	}
	if end < len(orig) {
		line += snippetEllipsis
	}
	return line
}

// indexRunes is the first index >= from where needle starts in hay, or -1.
func indexRunes(hay, needle []rune, from int) int {
	last := len(hay) - len(needle)
	for i := from; i <= last; i++ {
		if hay[i] != needle[0] {
			continue
		}
		j := 1
		for j < len(needle) && hay[i+j] == needle[j] {
			j++
		}
		if j == len(needle) {
			return i
		}
	}
	return -1
}

// foldRunes is s with every character folded (foldRune). One rune in, one rune out, so an index in the result is an
// index in []rune(s): the snippet is cut from the original text at the position found in the folded one.
func foldRunes(s string) []rune {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		out = append(out, foldRune(r))
	}
	return out
}

// foldTableSize covers Latin, Greek and Cyrillic, where nearly all the text is; the table is built once.
const foldTableSize = 0x530

var foldTable = sync.OnceValue(func() *[foldTableSize]rune {
	var t [foldTableSize]rune
	for r := range t {
		t[r] = foldSlow(rune(r))
	}
	return &t
})

// foldRune is the character a search compares: lower case, and a letter with a mark as its plain letter (é as e,
// ё as е). The unicode tables give the case, the accents table below the marks. The callers normalise to NFC before
// folding, so a letter typed as a base letter plus a combining mark matches its precomposed form. й is deliberately
// not folded to и: to a Russian reader it is a letter of its own, and "мои" must not find "мой". Known limit, left out
// on purpose: ß does not match "ss".
func foldRune(r rune) rune {
	if r < utf8.RuneSelf {
		if 'A' <= r && r <= 'Z' {
			return r + ('a' - 'A')
		}
		return r
	}
	if r < foldTableSize {
		return foldTable()[r]
	}
	return foldSlow(r)
}

func foldSlow(r rune) rune {
	r = unicode.ToLower(unicode.ToUpper(r)) // the upper-case round trip folds ς to σ, ſ to s
	if base, ok := accents[r]; ok {
		return base
	}
	return r
}

// accents maps a lower-case letter with a mark (or a stroke) to its plain letter.
var accents = func() map[rune]rune {
	groups := map[rune]string{
		'a': "àáâãäåāăąǎǻǟǡȁȃȧ", 'c': "çćĉċč", 'd': "ďđ", 'e': "èéêëēĕėęěȅȇȩ", 'g': "ĝğġģǧ", 'h': "ĥħ",
		'i': "ìíîïĩīĭįıǐȉȋ", 'j': "ĵ", 'k': "ķ", 'l': "ĺļľŀł", 'n': "ñńņňŉ", 'o': "òóôõöøōŏőǒǿȍȏ",
		'r': "ŕŗřȑȓ", 's': "śŝşšș", 't': "ţťŧț", 'u': "ùúûüũūŭůűųǔȕȗ", 'w': "ŵ", 'y': "ýÿŷ", 'z': "źżž",
		'е': "ё", 'і': "ї",
		'α': "ά", 'ε': "έ", 'η': "ή", 'ι': "ίϊΐ", 'ο': "ό", 'υ': "ύϋΰ", 'ω': "ώ",
	}
	m := map[rune]rune{}
	for base, letters := range groups {
		for _, r := range letters {
			m[r] = base
		}
	}
	return m
}()
