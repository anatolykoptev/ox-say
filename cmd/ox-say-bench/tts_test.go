package main

import (
	"testing"
	"time"
)

// #115: every case discards one synthesis before its timed runs, so the first
// cloned and the first Russian synthesis of a model do not sit in their medians.
// Mutation: tts.go ttsMedians, delete the discarded call -> RED.
func TestEveryCaseDiscardsItsWarmUp(t *testing.T) {
	var calls int
	run := func(tc ttsCase) (ttsRun, error) {
		calls++
		d := 10 * time.Second // a cold call: far off the warm ones
		if calls > 1 {
			d = time.Second
		}
		return ttsRun{ttfb: d, total: d, audioS: 1}, nil
	}
	row, err := ttsMedians(ttsCases[1], 3, run)
	if err != nil {
		t.Fatal(err)
	}
	if calls != 4 {
		t.Fatalf("%d synthesis calls for 3 runs, want 4 (one discarded)", calls)
	}
	if row.rtf != 1 {
		t.Fatalf("rtf %v: the cold call is in the median", row.rtf)
	}
}
