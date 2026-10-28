package meeting

import (
	"strings"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// stopwords are the words too common to show that two stretches of speech are
// the same sound: fillers, pronouns, articles, particles, yes/no. Only English
// and Russian are listed; every other language gets no stopword filtering, so
// all its words count as content and the order/bigram test alone guards it.
var stopwords = func() map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(`
a an the and or but so if of to in on at by for with from as is are was were be been am
it its this that these those there here i me my we us our you your he him his she her they them their
do does did not no yes yeah yep ok okay oh um uh well just also then than too very
will would can could should shall may might have has had what which who whom
да нет ну вот и а но или что это так как же ли бы не ни я мы ты вы он она оно они мой наш твой ваш его её ее их
в на с со к ко по за из у о об от до для при про без над под ещё еще уже тоже только`) {
		m[w] = true
	}
	return m
}()

func echoTokens(text string) []string {
	f := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '\''
	})
	out := f[:0]
	for _, w := range f {
		if w = strings.Trim(w, "'"); w != "" {
			out = append(out, w)
		}
	}
	return out
}

func contentTokens(text string, fn map[string]bool) []string {
	var out []string
	for _, w := range echoTokens(text) {
		if !stopwords[w] && !fn[w] {
			out = append(out, w)
		}
	}
	return out
}

// Meeting-derived function words: a word that occurs in at least
// fnTurnShare of all turns of a meeting of at least fnMinTurns turns (both
// channels together, each word counted once per turn) is a function word of
// the language being spoken, whatever it is, and counts like a stopword.
// A meeting shorter than fnMinTurns derives nothing: only the en/ru lists
// apply, and another language falls back to the order/bigram test alone.
const (
	fnMinTurns  = 10
	fnTurnShare = 0.3
	fnMinTurnsW = 3 // a word must also be in this many turns
)

func frequentWords(turns []Turn) map[string]bool {
	if len(turns) < fnMinTurns {
		return nil
	}
	count := map[string]int{}
	for _, t := range turns {
		seen := map[string]bool{}
		for _, w := range echoTokens(t.Text) {
			if !seen[w] {
				seen[w] = true
				count[w]++
			}
		}
	}
	var out map[string]bool
	for w, n := range count {
		if n >= fnMinTurnsW && float64(n) >= fnTurnShare*float64(len(turns)) {
			if out == nil {
				out = map[string]bool{}
			}
			out[w] = true
		}
	}
	return out
}

// echoMatch reports whether me is a re-capture of near, the far-side speech
// beside it. Three tests, all required:
//  1. echoShare of ALL me's words are in near (the plain share: an echo keeps
//     its small words, the owner's reply seldom does);
//  2. echoContentShare of me's content words (stopwords and fn, the meeting's
//     own frequent words, left out) are in near, and there is at least one: a
//     turn of nothing but common words is never an echo;
//  3. order: the matched content words follow near's order, or at least one
//     content bigram of me is also in near.
func echoMatch(me, near string, fn map[string]bool) bool {
	return echoMatchAt(me, near, fn, echoContentShare)
}

func echoMatchAt(me, near string, fn map[string]bool, share float64) bool {
	if voices.WordShare(me, near) < echoShare {
		return false
	}
	mc, nc := contentTokens(me, fn), contentTokens(near, fn)
	// No content words on either side: nothing to compare. Without this the
	// share below is 0/0 = NaN, which is not < share, and a turn of only
	// stopwords would fall through to lcs == common (0 == 0) and be an echo.
	if len(mc) == 0 || len(nc) == 0 {
		return false
	}
	bag := map[string]int{}
	for _, w := range nc {
		bag[w]++
	}
	common := 0
	for _, w := range mc {
		if bag[w] > 0 {
			bag[w]--
			common++
		}
	}
	if float64(common)/float64(len(mc)) < share {
		return false
	}
	return lcs(mc, nc) == common || sharesBigram(mc, nc)
}

// lcs is the length of the longest common subsequence of a and b.
func lcs(a, b []string) int {
	prev := make([]int, len(b)+1)
	for _, x := range a {
		cur := make([]int, len(b)+1)
		for j, y := range b {
			if x == y {
				cur[j+1] = prev[j] + 1
			} else {
				cur[j+1] = max(prev[j+1], cur[j])
			}
		}
		prev = cur
	}
	return prev[len(b)]
}

func sharesBigram(a, b []string) bool {
	seen := map[[2]string]bool{}
	for i := 0; i+1 < len(b); i++ {
		seen[[2]string{b[i], b[i+1]}] = true
	}
	for i := 0; i+1 < len(a); i++ {
		if seen[[2]string{a[i], a[i+1]}] {
			return true
		}
	}
	return false
}
