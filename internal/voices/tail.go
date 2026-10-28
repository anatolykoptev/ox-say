package voices

import (
	"crypto/sha256"
	"encoding/hex"
)

const (
	// anchorWords is how many words at the end of a ref_text must be found at
	// the end of the transcript. The bleed this guards against is the ref_text
	// tail past the audio: a reference that ends in words the clip never says
	// makes the model speak them. An overall similarity ratio cannot see it
	// when the overrun is under a fifth of the text (measured references
	// that ran 11, 6 and 4 words over scored 0.88-0.95 and still bled).
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
			if SameWord(w, window[j]) {
				matched++
				pos = j + 1
				break
			}
		}
	}
	return matched >= min(anchorNeed, len(anchor))
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

// sameWordProbes are the word pairs whose SameWord verdicts make up sameWordFingerprint: both sides of every
// branch (equal, under four letters, the tolerance at several lengths, Cyrillic runes). A pair is added here when
// SameWord gains a rule the existing pairs do not show.
var sameWordProbes = [][2]string{
	{"hello", "hello"},
	{"cat", "cut"},
	{"then", "than"}, // one edit at four letters is a spelling slip to SameWord; see TestSameWordProbes
	{"stol", "slon"},
	{"hello", "hallo"},
	{"hello", "hxllx"},
	{"abcdefghij", "abcdefghxx"},
	{"abcdefghij", "abcdefgxxx"},
	{"abcdefgh", "abcdefxx"},
	{"сохранит", "сохранить"},
	{"тридцать", "двадцать"},
}

// sameWordGenerated is a deterministic set of word pairs built from the rule's own inputs (length and edit count),
// not from a person's list of cases: for every length 1..16 over a Latin and a Cyrillic base word, the base against
// itself edited by 1..4 substitutions, 1..3 deletions, 1..3 insertions and one adjacent swap. A change to SameWord's
// tolerance at any length or edit kind changes a verdict somewhere in it, so sameWordFingerprint cannot go stale
// when a rule changes and nobody remembers to add a probe.
func sameWordGenerated() [][2]string {
	var out [][2]string
	for _, alphabet := range []string{"abcdefghijklmnop", "сохранитьтридцат"} {
		base := []rune(alphabet)
		for n := 1; n <= len(base); n++ {
			w := base[:n]
			edit := func(f func([]rune) []rune) {
				out = append(out, [2]string{string(w), string(f(append([]rune(nil), w...)))})
			}
			for k := 1; k <= 4 && k <= n; k++ {
				edit(func(r []rune) []rune {
					for i := 0; i < k; i++ {
						r[len(r)-1-i*2%len(r)] = '#'
					}
					return r
				})
			}
			for k := 1; k <= 3 && k < n; k++ {
				edit(func(r []rune) []rune { return r[:len(r)-k] })
			}
			for k := 1; k <= 3; k++ {
				edit(func(r []rune) []rune { return append(r, []rune("###")[:k]...) })
			}
			if n >= 2 {
				edit(func(r []rune) []rune { r[0], r[1] = r[1], r[0]; return r })
			}
		}
	}
	return out
}

// sameWordFingerprint is a short hash of same's verdict on every probe pair. It goes into the verdict cache key
// (tailParams), so a change in SameWord's result for any pair changes the key and every cached "transcript matches"
// verdict is dropped (the probes plus sameWordGenerated), instead of staying valid for a rule that no longer exists.
func sameWordFingerprint(same func(a, b string) bool) string {
	h := sha256.New()
	for _, p := range append(append([][2]string(nil), sameWordProbes...), sameWordGenerated()...) {
		h.Write([]byte(p[0]))
		h.Write([]byte{0})
		h.Write([]byte(p[1]))
		if same(p[0], p[1]) {
			h.Write([]byte{0, '1'})
		} else {
			h.Write([]byte{0, '0'})
		}
	}
	return hex.EncodeToString(h.Sum(nil)[:4])
}
