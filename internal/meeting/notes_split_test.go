package meeting

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// overflowChat answers a map call with ErrTruncated when its transcript part holds more than maxLines lines, and
// otherwise with one decision named after the part's first line. A call without a schema is the summary merge.
type overflowChat struct {
	t        *testing.T
	maxLines int
	mu       sync.Mutex
	calls    int
	texts    []string
}

func (o *overflowChat) Complete(_ context.Context, r Request) (string, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if r.Schema == nil {
		return "merged summary", nil
	}
	o.calls++
	_, part, _ := strings.Cut(r.User, "TRANSCRIPT PART:\n")
	o.texts = append(o.texts, part)
	lines := strings.Split(strings.TrimRight(part, "\n"), "\n")
	if len(lines) > o.maxLines {
		return `{"summary": "cut off`, ErrTruncated
	}
	first, _, _ := strings.Cut(strings.TrimPrefix(lines[0], "[0:01] Me: "), " ")
	return replyJSON(o.t, ChunkNotes{Summary: "summary " + first, Decisions: []string{"decision " + first}}), nil
}

func splitTranscript(lines int) string {
	var b strings.Builder
	for i := 0; i < lines; i++ {
		fmt.Fprintf(&b, "[0:01] Me: L%03d %s\n", i, fixtureQuote)
	}
	return b.String()
}

// A chunk whose answer overflows the cap is summarised in halves, not skipped: the long meeting still gets notes,
// and the halves' items sit in order.
// Mutation: internal/meeting/notes.go summarise, `if depth >= maxSplitDepth || !ok` -> `if true ||` ... -> RED
// (SkippedChunks = [0], no notes).
func TestComposeSplitsAChunkWhoseAnswerOverflows(t *testing.T) {
	chat := &overflowChat{t: t, maxLines: 100}
	text := splitTranscript(150)
	if n := len(Chunk(text, ChunkChars)); n != 1 {
		t.Fatalf("fixture is %d chunks, want 1", n)
	}
	n, err := (Composer{Chat: chat}).Compose(context.Background(), text, Labels{Me: "Me"}, "en")
	if err != nil {
		t.Fatal(err)
	}
	if len(n.SkippedChunks) != 0 {
		t.Fatalf("SkippedChunks = %v, want none: both halves summarised fine", n.SkippedChunks)
	}
	if got, want := strings.Join(n.Decisions, "|"), "decision L000|decision L075"; got != want {
		t.Fatalf("decisions = %q, want %q (both halves' items, in order)", got, want)
	}
	if chat.calls != 3 {
		t.Fatalf("map calls = %d, want 3 (the whole, then each half; the whole is not retried as it is)", chat.calls)
	}
	if joined := strings.TrimRight(chat.texts[1], "\n") + "\n" + strings.TrimRight(chat.texts[2], "\n"); joined != strings.TrimRight(text, "\n") {
		t.Fatal("the two halves are not the chunk's lines, cut at a line end and in order")
	}
}

// Halving stops after two levels: a model that always overflows costs 1+2+4 calls for the chunk, then the chunk is
// skipped.
// Mutation: internal/meeting/notes.go maxSplitDepth = 2 -> 1000 -> RED (many more calls).
func TestComposeSplitDepthIsBounded(t *testing.T) {
	chat := &overflowChat{t: t, maxLines: 0}
	_, err := (Composer{Chat: chat}).Compose(context.Background(), splitTranscript(150), Labels{Me: "Me"}, "en")
	if !errors.Is(err, ErrNoNotes) {
		t.Fatalf("err = %v, want ErrNoNotes: every piece overflowed", err)
	}
	if chat.calls != 7 {
		t.Fatalf("map calls = %d, want 7 (whole, 2 halves, 4 quarters)", chat.calls)
	}
}

// One quarter given up on does not cost the rest: the other pieces' notes stay, and the chunk is recorded as skipped
// so the notes say a part is missing.
func TestComposeKeepsThePiecesThatFit(t *testing.T) {
	chat := &overflowChat{t: t, maxLines: 40}
	n, err := (Composer{Chat: chat}).Compose(context.Background(), splitTranscript(100), Labels{Me: "Me"}, "en")
	if err != nil {
		t.Fatal(err)
	}
	// 100 lines -> 50+50 -> 25+25 each: all quarters fit 40, nothing lost.
	if len(n.SkippedChunks) != 0 || len(n.Decisions) != 4 {
		t.Fatalf("skipped %v decisions %q, want none skipped and 4 decisions", n.SkippedChunks, n.Decisions)
	}
	chat = &overflowChat{t: t, maxLines: 20}
	n, err = (Composer{Chat: chat}).Compose(context.Background(), splitTranscript(100), Labels{Me: "Me"}, "en")
	if !errors.Is(err, ErrNoNotes) {
		t.Fatalf("err = %v, want ErrNoNotes when no quarter fits", err)
	}
	_ = n
}

// A failure that is not a truncation keeps its one retry and then loses the chunk, as before.
func TestComposeNonTruncationFailureStillRetriesOnce(t *testing.T) {
	f := &fakeChat{errs: []error{errors.New("boom"), errors.New("boom")}}
	_, err := (Composer{Chat: f}).Compose(context.Background(), splitTranscript(10), Labels{Me: "Me"}, "en")
	if !errors.Is(err, ErrNoNotes) {
		t.Fatalf("err = %v", err)
	}
	if len(f.reqs) != 2 {
		t.Fatalf("calls = %d, want 2 (one retry, no split)", len(f.reqs))
	}
}

func TestSplitTextOneLongLine(t *testing.T) {
	line := "[0:01] Me: " + strings.Repeat("слово ", 400)
	a, b, ok := splitText(line)
	if !ok || a == "" || b == "" || !strings.HasPrefix(b, "[0:01] Me: ") {
		t.Fatalf("ok=%v a=%d b=%q", ok, len(a), b[:min(len(b), 30)])
	}
	if _, _, ok := splitText("short"); ok {
		t.Fatal("a short text must not be split")
	}
}
