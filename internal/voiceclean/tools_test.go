package voiceclean

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Every Runner call carries the tool it starts, so a caller need not guess from the path.
// Mutation: clean.go model(), pass j.ctx instead of withTool(j.ctx, ToolEngine) -> RED (the engine call is untagged).
func TestRunnerCallsAreTaggedWithTheirTool(t *testing.T) {
	requireTools(t)
	in := makeStereoWav(t, 48000, 1.0)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, fakeEngine(t, "1"))
	var mu sync.Mutex
	var seen []Tool
	o.Run = func(ctx context.Context, bin string, args []string) ([]byte, error) {
		mu.Lock()
		seen = append(seen, ToolOf(ctx))
		mu.Unlock()
		return execRunner(ctx, bin, args)
	}
	mustRun(t, o)
	counts := map[Tool]int{}
	for _, s := range seen {
		counts[s]++
	}
	if counts[ToolProbe] < 1 || counts[ToolFFmpeg] < 1 || counts[ToolEngine] != 1 || len(seen) != counts[ToolProbe]+counts[ToolFFmpeg]+counts[ToolEngine] {
		t.Errorf("tags seen: %v", seen)
	}
}

// What ffprobe says about an unreadable file goes to Detail (for the log), never into the sentence a user sees.
// Mutation: clean.go probe(), put tailClip(err.Error()) back into the message -> RED.
func TestFFprobeOutputStaysOutOfTheUserSentence(t *testing.T) {
	requireTools(t)
	bad := filepath.Join(t.TempDir(), "bad.wav")
	if err := os.WriteFile(bad, []byte("this is not audio SECRETWORDS"), 0o644); err != nil {
		t.Fatal(err)
	}
	o := opts(t, bad, filepath.Join(t.TempDir(), "o.wav"), 0.85, fakeEngine(t, "1"))
	_, err := Run(context.Background(), o)
	var ve *Error
	if !asError(err, &ve) || ve.Code != CodeInvalidRequest {
		t.Fatalf("got %v", err)
	}
	if ve.Msg != "This file is not audio or video OxSay can read." || strings.Contains(ve.Msg, "ffprobe") || strings.Contains(ve.Msg, "Invalid") {
		t.Errorf("message %q", ve.Msg)
	}
	if !strings.Contains(ve.Detail, "ffprobe") {
		t.Errorf("detail %q should keep the tool output for the log", ve.Detail)
	}
}
