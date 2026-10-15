package wordalign

import (
	"regexp"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// AlignWords times every written word of text (whitespace-separated,
// punctuation kept) from heard, the STT words of the same audio of dur s.
func AlignWords(text string, heard []voices.Word, dur float64) []voices.Word {
	written := writtenWords(text)
	var ref []string
	var owner []int
	for wi, w := range written {
		for _, t := range Words(w) {
			ref = append(ref, t)
			owner = append(owner, wi)
		}
	}
	hyp, heard := heardTokens(heard)
	tok := tokenTimes(ref, hyp, heard)
	fillGaps(tok, dur)
	out := make([]voices.Word, len(written))
	seen := make([]bool, len(written))
	for ti, wi := range owner {
		if !seen[wi] {
			out[wi], seen[wi] = voices.Word{W: written[wi], S: tok[ti].S, E: tok[ti].E}, true
		} else {
			out[wi].E = tok[ti].E
		}
	}
	for wi := len(out) - 1; wi >= 0; wi-- {
		if !seen[wi] {
			at := dur
			if wi+1 < len(out) {
				at = out[wi+1].S
			}
			out[wi] = voices.Word{W: written[wi], S: at, E: at}
		}
	}
	return settle(out, dur)
}

// settle keeps every time inside [0, dur] and the starts non-decreasing, so
// overlapping or overlong heard words cannot produce a backwards cue.
func settle(words []voices.Word, dur float64) []voices.Word {
	prev := 0.0
	for i := range words {
		s := min(max(words[i].S, prev, 0), dur)
		words[i].S, words[i].E = s, min(max(words[i].E, s), dur)
		prev = s
	}
	return words
}

var (
	firstGroup = regexp.MustCompile(`^[0-9]{1,3}$`)
	digitsOnly = regexp.MustCompile(`^[0-9]+$`)
	nextGroup  = regexp.MustCompile(`^[0-9]{3}[^\p{L}0-9]*$`)
)

// numberRuns groups consecutive items that are one number written in groups
// ("1", "000", "000."): the first is 1-3 digits, each next exactly 3 (the last
// may carry punctuation). Returned as [start, end) index pairs covering all n.
func numberRuns(n int, text func(int) string) [][2]int {
	var runs [][2]int
	for i := 0; i < n; {
		j := i + 1
		if firstGroup.MatchString(text(i)) {
			for j < n && nextGroup.MatchString(text(j)) {
				j++
				if !digitsOnly.MatchString(text(j - 1)) {
					break // punctuation ends the number
				}
			}
		}
		runs = append(runs, [2]int{i, j})
		i = j
	}
	return runs
}

// writtenWords splits text on whitespace, keeping the groups of one number
// ("1 000 000") together as a single written word.
func writtenWords(text string) []string {
	f := strings.Fields(text)
	var out []string
	for _, r := range numberRuns(len(f), func(i int) string { return f[i] }) {
		out = append(out, strings.Join(f[r[0]:r[1]], " "))
	}
	return out
}

// heardTokens tokenises the STT words with Words, the tokenizer WER and the
// written side use, so a word STT writes whole ("кто-то", "по-русски") lines up
// with its written form token for token. A heard word of several tokens gives
// each an equal share of its time; one with none (bare punctuation) is dropped.
func heardTokens(heard []voices.Word) ([]string, []voices.Word) {
	var toks []string
	var timed []voices.Word
	for _, h := range joinHeardNumbers(heard) {
		parts := Words(h.W)
		share := (h.E - h.S) / float64(max(1, len(parts)))
		for k, p := range parts {
			s := h.S + share*float64(k)
			toks = append(toks, p)
			timed = append(timed, voices.Word{W: p, S: s, E: s + share})
		}
	}
	return toks, timed
}

// joinHeardNumbers merges STT words that are the groups of one number.
func joinHeardNumbers(heard []voices.Word) []voices.Word {
	var out []voices.Word
	for _, r := range numberRuns(len(heard), func(i int) string { return heard[i].W }) {
		w := heard[r[0]]
		for _, h := range heard[r[0]+1 : r[1]] {
			w.W, w.E = w.W+" "+h.W, h.E
		}
		out = append(out, w)
	}
	return out
}

// tokenTimes walks the WER backtrace; unmatched ref tokens keep S = E = -1.
func tokenTimes(ref, hyp []string, heard []voices.Word) []voices.Word {
	_, move := werDP(ref, hyp)
	tok := make([]voices.Word, len(ref))
	for i := range tok {
		tok[i] = voices.Word{W: ref[i], S: -1, E: -1}
	}
	for i, j := len(ref), len(hyp); i > 0 || j > 0; {
		di, dj := int(move[i][j].di), int(move[i][j].dj)
		switch {
		case di == 1 && dj >= 1:
			tok[i-1].S, tok[i-1].E = heard[j-dj].S, heard[j-1].E
		case di > 1 && dj == 1:
			span := (heard[j-1].E - heard[j-1].S) / float64(di)
			for k := 0; k < di; k++ {
				tok[i-di+k].S = heard[j-1].S + span*float64(k)
				tok[i-di+k].E = tok[i-di+k].S + span
			}
		}
		i, j = i-di, j-dj
	}
	return tok
}

// fillGaps spreads each run of unmatched tokens evenly between its timed
// neighbours (or 0 / dur).
func fillGaps(tok []voices.Word, dur float64) {
	for i := 0; i < len(tok); {
		if tok[i].S >= 0 {
			i++
			continue
		}
		j := i
		for j < len(tok) && tok[j].S < 0 {
			j++
		}
		from, to := 0.0, dur
		if i > 0 {
			from = tok[i-1].E
		}
		if j < len(tok) {
			to = tok[j].S
		}
		w := max(0, to-from) / float64(j-i)
		for k := i; k < j; k++ {
			tok[k].S = from + w*float64(k-i)
			tok[k].E = tok[k].S + w
		}
		i = j
	}
}
