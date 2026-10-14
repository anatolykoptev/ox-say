package voices

const (
	// anchorWords is how many words at the end of a ref_text must be found at
	// the end of the transcript. The bleed this guards against is the ref_text
	// tail past the audio: a reference that ends in words the clip never says
	// makes the model speak them. An overall similarity ratio cannot see it
	// when the overrun is under a fifth of the text (en-deniro, en-william and
	// en-daniel: 10, 5 and 3 words over, ratios 0.88-0.95, all still bleeding).
	anchorWords = 3
	// anchorWindow is how far from the end of the transcript the anchor may
	// start: room for ASR dropping or splitting a word, not for a missing
	// sentence.
	anchorWindow = 6
	// anchorNeed is how many anchor words, in order, must match: one ASR
	// error in the last words is tolerated, two are not.
	anchorNeed = 2
)

// TranscriptMatches reports whether heard (the STT transcript of a clip) is
// the clip's ref_text: the words agree loosely overall (TextsMatch, tolerant
// of ASR errors) AND the ref_text ends where the audio ends (tailAnchored,
// which is what catches a text running past the audio).
func TranscriptMatches(ref, heard string) bool {
	return TextsMatch(ref, heard) && tailAnchored(normWords(ref), normWords(heard))
}

// tailAnchored reports whether the last anchorWords words of ref occur, in
// order and within edit tolerance, among the last anchorWindow words of heard.
func tailAnchored(ref, heard []string) bool {
	if len(ref) == 0 || len(heard) == 0 {
		return false
	}
	anchor := ref[max(0, len(ref)-anchorWords):]
	window := heard[max(0, len(heard)-anchorWindow):]
	matched, pos := 0, 0
	for _, w := range anchor {
		for j := pos; j < len(window); j++ {
			if sameWord(w, window[j]) {
				matched++
				pos = j + 1
				break
			}
		}
	}
	return matched >= min(anchorNeed, len(anchor))
}

// sameWord is equality up to an ASR spelling slip: one edit per five letters
// (at least one for words of four letters or more).
func sameWord(a, b string) bool {
	if a == b {
		return true
	}
	ra, rb := []rune(a), []rune(b)
	n := max(len(ra), len(rb))
	if n < 4 {
		return false
	}
	return editDistance(ra, rb) <= max(1, n/5)
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
