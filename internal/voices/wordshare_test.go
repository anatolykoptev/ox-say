package voices

import "testing"

// WordOverlap divides by the longer text, WordShare by the first: the same
// pair answers "are these one text" and "is the first inside the second".
// Mutation: internal/voices/script.go WordShare, divide by the longer text's word count
// instead of len(wa) -> RED (a short echo inside long speech scores low).
func TestWordOverlapAndWordShare(t *testing.T) {
	short := "ship the release on friday"
	long := "so the plan is to ship the release on friday after the review with everyone"
	if got := WordShare(short, long); got != 1 {
		t.Fatalf("WordShare(short, long) = %v, want 1: every word of short is in long", got)
	}
	if got := WordOverlap(short, long); got >= 0.5 {
		t.Fatalf("WordOverlap(short, long) = %v, want below 0.5: long has twice the words", got)
	}
	if WordOverlap("", "") != 0 || WordShare("", "x") != 0 {
		t.Fatal("empty text shares nothing")
	}
	if !TextsMatch("Hello, world", "hello world") {
		t.Fatal("TextsMatch must keep ignoring case and punctuation")
	}
}

// The typographic apostrophes (U+2019, U+02BC) fold into a plain one: a typed
// "don’t" is the same word as the STT's "don't". Without the fold "don't"
// splits into "don" + "t", a correct text can drop below the match threshold,
// and its ref_text is replaced for no reason (#439).
// Mutation: internal/voices/script.go normWords — delete the `apostrophes.Replace` fold -> RED.
func TestNormWordsFoldsTypographicApostrophes(t *testing.T) {
	for _, typed := range []string{"I don’t think so", "I donʼt think so"} {
		if !TextsMatch(typed, "I don't think so") {
			t.Fatalf("TextsMatch(%q, \"I don't think so\") = false, want true", typed)
		}
	}
	if got := normWords("don’t"); len(got) != 1 || got[0] != "don't" {
		t.Fatalf("normWords(\"don’t\") = %v, want [\"don't\"]", got)
	}
}
