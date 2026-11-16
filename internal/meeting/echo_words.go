package meeting

import (
	"math"
	"sort"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// withoutEcho removes the echo of the far side from one "me" turn at the word
// level and returns what is left of it, re-split into turns by the usual
// pause rule (none when everything was echo). changed is false, and the turn
// is to be kept as it is, when no word was judged an echo.
//
// On speakers the owner's short reply to a question lands in the same turn as
// the microphone's echo of that question ("<the question> I'm good. Yeah."),
// so judging the turn as a whole either loses the reply or keeps the echo.
// Instead, for every far-side turn, echoWords picks the words of the turn
// that are evidence of an echo of a specific far-side word; every other word,
// whatever it overlaps in time, stays.
func withoutEcho(t Turn, all []Turn, fn map[string]bool) (rest []Turn, changed bool) {
	if len(t.Words) == 0 {
		return nil, false
	}
	drop := make([]bool, len(t.Words))
	for _, u := range all {
		if u.Speaker != SpeakerThem {
			continue
		}
		for _, i := range echoWords(t, u, all, fn) {
			drop[i] = true
			changed = true
		}
	}
	if !changed {
		return nil, false
	}
	var kept []stt.Word
	for i, w := range t.Words {
		if !drop[i] {
			kept = append(kept, w)
		}
	}
	return group(kept, SpeakerMe), true
}

// echoWords returns the indices of the words of t that re-capture the
// far-side turn u. Inside u widened by echoLatency, the words of t are
// aligned with u's words (alignedWords). The stretch from the first to the
// last aligned word must, as a turn of its own, be an echo (isEcho); only
// then are words removed, and only these:
//   - the aligned words, each of which matches a far-side word spoken within
//     echoLatency of it;
//   - a word that is not aligned but is a near-match (similarWord) of a
//     far-side word that no word of t is aligned with, spoken within
//     echoLatency of it: a garbled echo word. Such a word is removed when it
//     lies inside the stretch, or follows a run of removed words directly
//     before or after it.
//
// A word of the owner between or beside the echo that is evidence of no
// far-side word stays, however long the far side keeps talking.
func echoWords(t, u Turn, all []Turn, fn map[string]bool) []int {
	lo, hi := wordsWithin(t.Words, u.S-echoLatency, u.E+echoLatency)
	if hi-lo < echoMinWords {
		return nil
	}
	reg := t.Words[lo:hi]
	pairs := alignedWords(reg, u.Words)
	if len(pairs) == 0 {
		return nil
	}
	a, b := pairs[0].me, pairs[len(pairs)-1].me+1
	span := group(reg[a:b], SpeakerMe)
	if len(span) != 1 || !isEcho(span[0], all, fn) {
		return nil
	}
	echo := make([]bool, len(reg))
	taken := make([]bool, len(u.Words))
	for _, p := range pairs {
		echo[p.me], taken[p.far] = true, true
	}
	garbled := func(i int) bool { return nearEcho(reg[i], u.Words, taken) }
	for i := a; i < b; i++ {
		echo[i] = echo[i] || garbled(i)
	}
	for ; a > 0 && garbled(a-1); a-- {
		echo[a-1] = true
	}
	for ; b < len(reg) && garbled(b); b++ {
		echo[b] = true
	}
	var out []int
	for i, e := range echo {
		if e {
			out = append(out, lo+i)
		}
	}
	return out
}

// wordsWithin returns the range [lo, hi) of the time-ordered words whose
// midpoint lies in [from, to].
func wordsWithin(words []stt.Word, from, to float64) (lo, hi int) {
	lo = len(words)
	for i, w := range words {
		if mid := wordMid(w); mid >= from && mid <= to {
			lo = min(lo, i)
			hi = i + 1
		}
	}
	if lo > hi {
		return 0, 0
	}
	return lo, hi
}

// wordPair is a word of the "me" turn (me) matched to a far-side word (far).
type wordPair struct{ me, far int }

// alignedWords returns the matched pairs of an ordered alignment (longest
// common subsequence) of the normalized words of me and far, sorted by me. A
// pair may only be matched when the two words are spoken within echoLatency
// of each other: a word of the owner's reply that also occurs in the question,
// but at another time, is not matched.
func alignedWords(me, far []stt.Word) []wordPair {
	mt, ft := wordTokens(me), wordTokens(far)
	n, m := len(me), len(far)
	dp := make([][]int, n+1)
	for i := range dp {
		dp[i] = make([]int, m+1)
	}
	pair := func(i, j int) bool {
		return mt[i] != "" && mt[i] == ft[j] && together(me[i], far[j])
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			dp[i][j] = max(dp[i-1][j], dp[i][j-1])
			if pair(i-1, j-1) {
				dp[i][j] = max(dp[i][j], dp[i-1][j-1]+1)
			}
		}
	}
	var out []wordPair
	for i, j := n, m; i > 0 && j > 0; {
		switch {
		case pair(i-1, j-1) && dp[i][j] == dp[i-1][j-1]+1:
			out = append(out, wordPair{i - 1, j - 1})
			i, j = i-1, j-1
		case dp[i-1][j] >= dp[i][j-1]:
			i--
		default:
			j--
		}
	}
	sort.Slice(out, func(x, y int) bool { return out[x].me < out[y].me })
	return out
}

// together: two words spoken within echoLatency of each other.
func together(a, b stt.Word) bool { return math.Abs(wordMid(a)-wordMid(b)) <= echoLatency }

// nearEcho reports whether w is a garbled echo of a far-side word that no
// word of the turn is aligned with (taken marks the aligned ones).
func nearEcho(w stt.Word, far []stt.Word, taken []bool) bool {
	tok := strings.Join(echoTokens(w.W), " ")
	for j, f := range far {
		if !taken[j] && together(w, f) && similarWord(tok, strings.Join(echoTokens(f.W), " ")) {
			return true
		}
	}
	return false
}

const (
	// echoSimilarMin: a word shorter than this is never a near-match, only an
	// equal match: "yes" and "yeah" are one edit from half the small words.
	echoSimilarMin = 4
	// echoSimilarDiv: a near-match differs by at most 1/echoSimilarDiv of the
	// longer word's letters (and by at least one letter).
	echoSimilarDiv = 4
)

// similarWord: a and b are the same word, or both are at least echoSimilarMin
// letters long and differ by a few letters (a recognizer's slip on one word).
func similarWord(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	if a == b {
		return true
	}
	ra, rb := []rune(a), []rune(b)
	long := max(len(ra), len(rb))
	if min(len(ra), len(rb)) < echoSimilarMin {
		return false
	}
	return editDistance(ra, rb) <= max(1, long/echoSimilarDiv)
}

// editDistance is the Levenshtein distance between a and b.
func editDistance(a, b []rune) int {
	prev := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := range a {
		cur := make([]int, len(b)+1)
		cur[0] = i + 1
		for j := range b {
			cost := 1
			if a[i] == b[j] {
				cost = 0
			}
			cur[j+1] = min(prev[j+1]+1, cur[j]+1, prev[j]+cost)
		}
		prev = cur
	}
	return prev[len(b)]
}

// wordTokens normalizes each word the way echoTokens does; a word with no
// letter or digit becomes "" and matches nothing.
func wordTokens(words []stt.Word) []string {
	out := make([]string, len(words))
	for i, w := range words {
		out[i] = strings.Join(echoTokens(w.W), " ")
	}
	return out
}

// wordMid is the middle of a word's span: the point a word is placed at when
// judging whether two words are spoken together.
func wordMid(w stt.Word) float64 { return w.S + (w.E-w.S)/2 }
