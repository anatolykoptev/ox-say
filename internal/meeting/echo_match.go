package meeting

import (
	"strings"
	"unicode"
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
да нет ну вот и а но или что это так как же ли бы не ни я мы ты вы он она оно они мой наш твой ваш его её их
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

func contentTokens(text string) []string {
	var out []string
	for _, w := range echoTokens(text) {
		if !stopwords[w] {
			out = append(out, w)
		}
	}
	return out
}

// echoMatch reports whether me is a re-capture of near, the far-side speech
// beside it. Stopwords never count (a turn of nothing else is never a match),
// at least echoShare of me's content words must be in near, and the match
// needs order: the content words matched in the same order as in near, or at
// least one content bigram of me that near also has. The bag share alone
// matches the owner talking over the far side with the same common words.
func echoMatch(me, near string) bool {
	mc, nc := contentTokens(me), contentTokens(near)
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
	if float64(common)/float64(len(mc)) < echoShare {
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
