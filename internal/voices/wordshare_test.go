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
