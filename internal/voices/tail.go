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
)

// tailParams identifies the tail check's behaviour for the verdict cache.
func tailParams() string {
	return fmt.Sprintf("tail:%d,%d,%d,%d,%d", anchorWords, anchorFree, anchorBudget, sameWordMinLen, sameWordDiv)
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
func tailAnchored(ref, heard []string) bool {
	if len(ref) == 0 || len(heard) == 0 {
		return false
	}
	r := ref[max(0, len(ref)-anchorWords):]
	budget := anchorBudget
	if len(r) <= 2 {
		budget = 0
	}
	n, m := len(r), len(heard)
	// d[i][j]: fewest edits aligning r[:i] to a stretch of heard ending at j.
	d := make([][]int, n+1)
	for i := range d {
		d[i] = make([]int, m+1)
		if i > 0 {
			d[i][0] = i
		}
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			sub := 1
			if SameWord(r[i-1], heard[j-1]) {
				sub = 0
			}
			best := min(d[i-1][j-1]+sub, d[i-1][j]+1, d[i][j-1]+1)
			if j >= 2 && SameWord(r[i-1], heard[j-2]+heard[j-1]) { // ref word split in two
				best = min(best, d[i-1][j-2]+1)
			}
			if i >= 2 && SameWord(r[i-2]+r[i-1], heard[j-1]) { // two ref words merged
				best = min(best, d[i-2][j-1]+1)
			}
			d[i][j] = best
		}
	}
	for e := 0; e <= anchorFree && e <= m; e++ {
		if d[n][m-e] <= budget {
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
