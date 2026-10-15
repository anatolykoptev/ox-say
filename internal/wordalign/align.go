package wordalign

import (
	"strings"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// AlignWords times every written word of text (whitespace-separated,
// punctuation kept) from heard, the STT words of the same audio of dur s.
func AlignWords(text string, heard []voices.Word, dur float64) []voices.Word {
	written := strings.Fields(text)
	var ref []string
	var owner []int
	for wi, w := range written {
		for _, t := range Words(w) {
			ref = append(ref, t)
			owner = append(owner, wi)
		}
	}
	hyp := make([]string, len(heard))
	for i, h := range heard {
		hyp[i] = strings.Join(Words(h.W), "")
	}
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
