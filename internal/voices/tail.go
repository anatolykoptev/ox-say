package voices

import "fmt"

// The tail alignment's parameters. They are vars only so a test can change
// one; tailParams folds every one of them (and SameWord's tolerance) into the
// repair verdict cache key, so a change here re-checks every voice by itself.
var (
	// anchorWords is how many words at the end of a ref_text are aligned to
	// the end of the transcript. The bleed this guards against is the
	// ref_text tail past the audio: a reference that ends in words the clip
	// never says makes the model speak them. An overall similarity ratio
	// cannot see it when the overrun is under a fifth of the text (measured
	// references that ran 11, 6 and 4 words over scored 0.88-0.95 and still
	// bled). The window must be wide enough that a tail phrase said earlier
	// in the clip cannot stand in for the real ending.
	anchorWords = 5
	// anchorFree is how many extra words the recognizer may have appended
	// after the reference's last word ("thank you", "ага"): not part of the
	// reference, not a sign that the reference runs past the audio.
	anchorFree = 2
	// anchorBudget is how many word edits (substitution, insertion, deletion,
	// one word split in two or two merged into one) the aligned tail may need:
	// one recognizer slip is tolerated, two are not. A reference of two words
	// or fewer tolerates none.
	anchorBudget = 1
	// sameWordMinLen and sameWordDiv define SameWord: words under
	// sameWordMinLen letters must be equal; longer ones may differ by
	// max(1, len/sameWordDiv) edits.
	sameWordMinLen = 4
	sameWordDiv    = 5
	// anchorBudgetEarlyEnd is the budget when the transcript's last word ends
	// more than clipEndSlack seconds before the clip does. A reference cut by
	// the clip end has speech running to the very end of the clip, so a
	// clip whose speech stops early is not cut, and two recognizer slips in
	// its tail (short words like "to"/"too" that SameWord cannot absorb) do
	// not make it broken.
	anchorBudgetEarlyEnd = 2
	clipEndSlack         = 0.15
)

// fillers are hesitation sounds a recognizer writes down but a reference
// does not: a heard filler is a free insertion in the tail alignment. Kept
// to sounds that are never content words, plus the Russian "а"/"ну"/"ага"
// that a reference may also contain (a match still counts as a match; only an
// unmatched heard filler is free).
var fillers = map[string]bool{
	"um": true, "uh": true, "er": true, "ah": true, "hmm": true, "mm": true,
	"э": true, "эм": true, "ну": true, "а": true, "м": true, "ага": true, "угу": true,
}

// tailParams identifies the tail check's behaviour for the verdict cache.
func tailParams() string {
	return fmt.Sprintf("tail:%d,%d,%d,%d,%d,%d,%v,f%d", anchorWords, anchorFree, anchorBudget, sameWordMinLen, sameWordDiv,
		anchorBudgetEarlyEnd, clipEndSlack, len(fillers))
}

// TranscriptMatches reports whether heard (the STT transcript of a clip) is
// the clip's ref_text: the words agree loosely overall (TextsMatch, tolerant
// of ASR errors) AND the ref_text ends where the audio ends (tailAnchored,
// which is what catches a text running past the audio).
func TranscriptMatches(ref, heard string) bool {
	return TextsMatch(ref, heard) && tailAnchored(normWords(ref), normWords(heard))
}

// tailAnchored reports whether the last anchorWords words of ref are the end
// of heard: a word-level edit alignment of the ref tail against heard, where
// the alignment may start anywhere in heard but must finish within anchorFree
// words of its end, costs at most anchorBudget edits and counts SameWord
// words as equal. A recognizer that adds, drops or splits a word at the end
// still anchors; a reference whose tail merely occurs earlier in the clip (its
// real ending cut off) does not, because the words before the repeat then
// disagree as well.
func tailAnchored(ref, heard []string) bool { return tailAnchoredWithin(ref, heard, anchorBudget) }

// TranscriptMatchesTimed is TranscriptMatches for a transcript with word
// timestamps from a clip of clipSeconds: when the last heard word ends well
// before the clip does, the clip was not cut mid-speech and the tail check
// gets anchorBudgetEarlyEnd edits instead of anchorBudget.
func TranscriptMatchesTimed(ref string, words []Word, clipSeconds float64) bool {
	heard := joinWords(words)
	if TranscriptMatches(ref, heard) {
		return true
	}
	if len(words) == 0 || clipSeconds-words[len(words)-1].E <= clipEndSlack {
		return false
	}
	return TextsMatch(ref, heard) && tailAnchoredWithin(normWords(ref), normWords(heard), anchorBudgetEarlyEnd)
}

func tailAnchoredWithin(ref, heard []string, budget int) bool {
	if len(ref) == 0 || len(heard) == 0 {
		return false
	}
	r := ref[max(0, len(ref)-anchorWords):]
	if len(r) <= 2 {
		budget = 0
	}
	n, m := len(r), len(heard)
	// d[i][j]: fewest edits aligning r[:i] to a stretch of heard ending at j.
	// f is d without the option that the alignment ENDS on an inserted heard
	// word: a trailing unmatched word is an "extra" (anchorFree), judged by
	// repeatsEarlier, not a one-edit insertion.
	f := make([][]int, n+1)
	d := make([][]int, n+1)
	for i := range d {
		d[i] = make([]int, m+1)
		f[i] = make([]int, m+1)
		if i > 0 {
			d[i][0], f[i][0] = i, i
		}
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			sub := 1
			if SameWord(r[i-1], heard[j-1]) {
				sub = 0
			}
			ins := 1
			if fillers[heard[j-1]] {
				ins = 0
			}
			best := min(d[i-1][j-1]+sub, d[i-1][j]+1)
			if j >= 2 && SameWord(r[i-1], heard[j-2]+heard[j-1]) { // ref word split in two
				best = min(best, d[i-1][j-2]+1)
			}
			if i >= 2 && SameWord(r[i-2]+r[i-1], heard[j-1]) { // two ref words merged
				best = min(best, d[i-2][j-1]+1)
			}
			f[i][j] = best
			d[i][j] = min(best, d[i][j-1]+ins)
		}
	}
	for e := 0; e <= anchorFree && e <= m; e++ {
		if f[n][m-e] <= budget && (e == 0 || !repeatsEarlier(ref, heard, e)) {
			return true
		}
	}
	return false
}

// repeatsEarlier reports whether the end of heard, the tail plus the e words
// after it, also reads as a stretch of ref that is not ref's end. When the
// recognizer's extra words are in fact the words that follow an EARLIER
// occurrence of the tail phrase in the reference ("...store today and we went
// to the store today", heard stopping after "today and"), the tail matched
// the wrong place and the reference's real ending was cut off.
func repeatsEarlier(ref, heard []string, e int) bool {
	l := min(anchorWords+e, len(heard))
	x := heard[len(heard)-l:]
	for p := l; p < len(ref); p++ { // ref[p-l:p] ends before ref's last word
		same := true
		for k := 0; same && k < len(x); k++ {
			same = SameWord(ref[p-l+k], x[k])
		}
		if same { // every word, so a heard extra that merely differs is not a repeat
			return true
		}
	}
	return false
}

// SameWord is equality up to an ASR spelling slip: one edit per sameWordDiv
// letters (at least one for words of sameWordMinLen letters or more).
func SameWord(a, b string) bool {
	if a == b {
		return true
	}
	ra, rb := []rune(a), []rune(b)
	n := max(len(ra), len(rb))
	if n < sameWordMinLen {
		return false
	}
	return editDistance(ra, rb) <= max(1, n/sameWordDiv)
}

func editDistance(a, b []rune) int {
	prev := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		cur := make([]int, len(b)+1)
		cur[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
		}
		prev = cur
	}
	return prev[len(b)]
}
