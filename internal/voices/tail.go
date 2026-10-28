package voices

const (
	// anchorWords is how many words at the end of a ref_text must be found at
	// the end of the transcript. The bleed this guards against is the ref_text
	// tail past the audio: a reference that ends in words the clip never says
	// makes the model speak them. An overall similarity ratio cannot see it
	// when the overrun is under a fifth of the text (measured references
	// that ran 11, 6 and 4 words over scored 0.88-0.95 and still bled).
	anchorWords = 3
	// anchorDrop is how many words the recognizer may have dropped at the very
	// end of the clip (a trailing word clipped by the audio edge). It is not
	// room for a missing sentence, and it is not room for a tail that merely
	// occurs earlier in the clip.
	anchorDrop = 1
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

// tailAnchored reports whether the last anchorWords words of ref line up, word
// for word and within SameWord tolerance, with the END of heard (at least
// anchorNeed of them). The alignment is positional: ref's last word against
// heard's last word, and so on backwards. Heard may end up to anchorDrop words
// early (every ref word then sits one further from the end), never later: a
// search for the tail words anywhere near the end would accept a reference
// whose tail repeats words said earlier in the clip while its real ending was
// cut off.
func tailAnchored(ref, heard []string) bool {
	if len(ref) == 0 || len(heard) == 0 {
		return false
	}
	anchor := ref[max(0, len(ref)-anchorWords):]
	for drop := 0; drop <= anchorDrop; drop++ {
		matched := 0
		for i := range anchor { // i-th word from the end of both
			j := len(heard) - 1 - i + drop
			if j < len(heard) && j >= 0 && SameWord(anchor[len(anchor)-1-i], heard[j]) {
				matched++
			}
		}
		if matched >= min(anchorNeed, len(anchor)) {
			return true
		}
	}
	return false
}

// SameWord is equality up to an ASR spelling slip: one edit per five letters
// (at least one for words of four letters or more).
func SameWord(a, b string) bool {
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
