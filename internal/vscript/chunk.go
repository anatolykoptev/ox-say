package vscript

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

var clauseMarks = []string{";:", "—–", ","}

func runes(s string) int { return utf8.RuneCountInString(s) }

// chunkParagraph groups sentences greedily up to TargetChars; an over-long
// sentence is split first; a last chunk under MinChars joins its predecessor
// when both fit MaxChars.
func chunkParagraph(sents []string, o Options) []string {
	var out []string
	cur := ""
	for _, s := range sents {
		for _, p := range splitLong(s, o) {
			switch {
			case cur == "":
				cur = p
			case runes(cur)+1+runes(p) <= o.TargetChars:
				cur += " " + p
			default:
				out = append(out, cur)
				cur = p
			}
		}
	}
	if cur != "" {
		out = append(out, cur)
	}
	if n := len(out); n > 1 && runes(out[n-1]) < o.MinChars && runes(out[n-2])+1+runes(out[n-1]) <= o.MaxChars {
		out[n-2] += " " + out[n-1]
		out = out[:n-1]
	}
	return out
}

// splitLong cuts s into pieces of at most MaxChars runes: every cut lands at
// or before MaxChars, and the remainder is split again until it fits.
func splitLong(s string, o Options) []string {
	if runes(s) <= o.MaxChars {
		return []string{s}
	}
	rs := []rune(s)
	cut := bestCut(rs, o)
	return append([]string{strings.TrimSpace(string(rs[:cut]))}, splitLong(strings.TrimSpace(string(rs[cut:])), o)...)
}

func bestCut(rs []rune, o Options) int {
	for _, marks := range clauseMarks {
		if c := nearest(rs, o, func(i int) bool {
			return strings.ContainsRune(marks, rs[i]) && i+1 < len(rs) && rs[i+1] == ' '
		}); c > 0 {
			return c
		}
	}
	if c := nearest(rs, o, func(i int) bool { return rs[i] == ' ' }); c > 0 {
		return c
	}
	return min(o.TargetChars, len(rs)-1)
}

// nearest is the cut (index after the mark) closest to TargetChars among
// marks whose left piece fits MaxChars and whose right piece is not tiny.
func nearest(rs []rune, o Options, ok func(i int) bool) int {
	best, bestDist := -1, len(rs)
	for i := o.MinChars; i < len(rs)-o.MinChars && i+1 <= o.MaxChars; i++ {
		if !ok(i) {
			continue
		}
		if d := abs(i + 1 - o.TargetChars); d < bestDist {
			best, bestDist = i+1, d
		}
	}
	return best
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// Spoken is the text the engine reads, and the text a take is gated against.
// Two rewrites. A leading "(x)" becomes "x —" — the engine parses any leading
// ASCII "(…)" as a style tag (audio.cpp session.cpp:99-117), with or without
// a style of ours; it repeats until the text no longer opens with "(" (after
// white space and format characters), each pass consuming one "(". Then the
// unambiguous Russian abbreviations (spokenForms) are written out.
func Spoken(text string) string {
	return expandAbbreviations(unparen(text))
}

func unparen(text string) string {
	s := trimLead(text)
	for strings.HasPrefix(s, "(") {
		inner, rest, closed := strings.Cut(s[1:], ")")
		rest = trimLead(strings.TrimLeft(rest, ")"))
		inner = strings.TrimSpace(inner)
		switch {
		case !closed:
			s = trimLead(inner)
		case inner == "":
			s = rest
		case rest == "":
			s = inner
		default:
			s = inner + " — " + rest
		}
	}
	return strings.TrimSpace(s)
}

// trimLead drops leading white space and format characters (zero-width
// spaces, BOM) that would hide a "(" from the prefix check.
func trimLead(s string) string {
	return strings.TrimLeftFunc(s, func(r rune) bool { return unicode.IsSpace(r) || unicode.Is(unicode.Cf, r) })
}
