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
// Instead, for every far-side turn, the stretch of the turn's words that
// aligns with that far-side turn (alignedWords) is cut out when, taken as a
// turn of its own, it is an echo (isEcho): the same words, in order, spoken
// at the same time. The owner's words around the stretch survive.
func withoutEcho(t Turn, all []Turn, fn map[string]bool) (rest []Turn, changed bool) {
	if len(t.Words) == 0 {
		return nil, false
	}
	drop := make([]bool, len(t.Words))
	for _, u := range all {
		if u.Speaker != SpeakerThem {
			continue
		}
		if a, b, ok := echoSpan(t, u, all, fn); ok {
			for i := a; i < b; i++ {
				drop[i] = true
				changed = true
			}
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

// echoSpan finds the words [a, b) of t that re-capture the far-side turn u: the
// first to the last word of t, inside u widened by echoLatency, that align
// with u's words, provided that stretch alone is an echo.
func echoSpan(t, u Turn, all []Turn, fn map[string]bool) (a, b int, ok bool) {
	lo, hi := wordsWithin(t.Words, u.S-echoLatency, u.E+echoLatency)
	if hi-lo < echoMinWords {
		return 0, 0, false
	}
	seeds := alignedWords(t.Words[lo:hi], u.Words)
	if len(seeds) == 0 {
		return 0, 0, false
	}
	a, b = lo+seeds[0], lo+seeds[len(seeds)-1]+1
	span := group(t.Words[a:b], SpeakerMe)
	if len(span) != 1 || !isEcho(span[0], all, fn) {
		return 0, 0, false
	}
	a, b = extendSpan(t.Words, a, b, u)
	return a, b, true
}

// echoEdge: how many words beside an echo stretch may go with it. The
// recognizer garbles the first or last word of an echo more often than the
// middle, and a garbled word matches nothing, so it would be left behind as a
// one-word turn of its own. Only a word spoken while the far-side turn was in
// progress goes: the owner's reply comes after it.
const echoEdge = 1

// extendSpan widens the echo words [a, b) by up to echoEdge unmatched words on
// each side, as long as they lie within the far-side turn u itself.
func extendSpan(words []stt.Word, a, b int, u Turn) (lo, hi int) {
	inside := func(w stt.Word) bool { return wordMid(w) >= u.S && wordMid(w) <= u.E }
	lo, hi = a, b
	for n := 0; n < echoEdge && lo > 0 && inside(words[lo-1]); n++ {
		lo--
	}
	for n := 0; n < echoEdge && hi < len(words) && inside(words[hi]); n++ {
		hi++
	}
	return lo, hi
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

// alignedWords returns the indices of the words of me that line up with words
// of far: an ordered alignment (longest common subsequence) of the normalized
// words in which a pair may only be matched when the two words are spoken
// within echoLatency of each other. A word of the owner's reply that also
// occurs in the question, but at another time, is not matched.
func alignedWords(me, far []stt.Word) []int {
	mt, ft := wordTokens(me), wordTokens(far)
	n, m := len(me), len(far)
	dp := make([][]int, n+1)
	for i := range dp {
		dp[i] = make([]int, m+1)
	}
	pair := func(i, j int) bool {
		return mt[i] != "" && mt[i] == ft[j] &&
			math.Abs(wordMid(me[i])-wordMid(far[j])) <= echoLatency
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			dp[i][j] = max(dp[i-1][j], dp[i][j-1])
			if pair(i-1, j-1) {
				dp[i][j] = max(dp[i][j], dp[i-1][j-1]+1)
			}
		}
	}
	var out []int
	for i, j := n, m; i > 0 && j > 0; {
		switch {
		case pair(i-1, j-1) && dp[i][j] == dp[i-1][j-1]+1:
			out = append(out, i-1)
			i, j = i-1, j-1
		case dp[i-1][j] >= dp[i][j-1]:
			i--
		default:
			j--
		}
	}
	sort.Ints(out)
	return out
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
