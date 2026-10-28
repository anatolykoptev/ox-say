package vscript

import (
	"errors"
	"strings"
	"testing"
)

// #147 item 1: two trailing pauses add up and are capped at MaxPause.
// Mutation: markup.go `PauseAfter = min(pending, MaxPause)` -> `= pending` -> RED.
func TestTrailingPauseCapped(t *testing.T) {
	cs, err := Parse("Привет. [pause 6s][pause 6s]", testOpts)
	if err != nil {
		t.Fatal(err)
	}
	if got := cs[len(cs)-1].PauseAfter; got != MaxPause {
		t.Errorf("trailing PauseAfter = %v, want %v", got, MaxPause)
	}
}

// #147 item 2: a format character before an inner "(" is trimmed on the
// inner text too, so Spoken never opens with Cf + "(".
// Mutation: chunk.go unparen drops trimLead(inner) -> RED.
func TestSpokenInnerFormatCharBeforeParen(t *testing.T) {
	got := Spoken("(​(a) b) c")
	if got != "a — b — c" {
		t.Errorf("Spoken = %q, want %q", got, "a — b — c")
	}
}

// #147 item 4: option errors are plain configuration errors, not script lines.
// Mutation: markup.go validate returns &LineError{1, ...} again -> RED.
func TestOptionErrorsAreNotLineErrors(t *testing.T) {
	_, err := Parse("Привет.", Options{TargetChars: 0, MaxChars: 10, MinChars: 1, MaxScriptChars: 100})
	var le *LineError
	if err == nil || errors.As(err, &le) || strings.HasPrefix(err.Error(), "line ") {
		t.Errorf("option error = %v (LineError %v)", err, le)
	}
}
