package meeting

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func mergeLines(t *testing.T, a, b ChunkNotes) Notes {
	t.Helper()
	return MergeChunks([]ChunkNotes{a, b}, Labels{Me: "Anatoly", Them: "Other"})
}

// Two lines that differ by one number are two facts, not one repeated fact.
// Mutation: internal/meeting/notes.go factsDiffer, drop the `numbersOf(a) !=
// numbersOf(b) ||` term -> RED.
func TestMergeKeepsDecisionsAndQuestionsThatDifferByANumber(t *testing.T) {
	a := ChunkNotes{Decisions: []string{"Budget 5000 dollars for ads this quarter"}, OpenQuestions: []string{"Can we ship 3 versions by the launch date"}}
	b := ChunkNotes{Decisions: []string{"Budget 7000 dollars for ads this quarter"}, OpenQuestions: []string{"Can we ship 4 versions by the launch date"}}
	got := mergeLines(t, a, b)
	if len(got.Decisions) != 2 || len(got.OpenQuestions) != 2 {
		t.Fatalf("decisions %q, questions %q: a differing number must keep both", got.Decisions, got.OpenQuestions)
	}
}

// Mutation: internal/meeting/notes.go factsDiffer, drop the two `namesMissing`
// terms -> RED.
func TestMergeKeepsDecisionsThatDifferByAName(t *testing.T) {
	a := ChunkNotes{Decisions: []string{"Pay Bob 500 dollars for the shoot"}, OpenQuestions: []string{"Who tells Bob about the new schedule"}}
	b := ChunkNotes{Decisions: []string{"Pay Ann 500 dollars for the shoot"}, OpenQuestions: []string{"Who tells Ann about the new schedule"}}
	got := mergeLines(t, a, b)
	if len(got.Decisions) != 2 || len(got.OpenQuestions) != 2 {
		t.Fatalf("decisions %q, questions %q: a differing name must keep both", got.Decisions, got.OpenQuestions)
	}
}

// Case alone is not a name: "Use" at a sentence start still equals "use".
func TestMergeStillMergesRepeatsThatDifferOnlyInCaseAndPunctuation(t *testing.T) {
	a := ChunkNotes{Decisions: []string{"Use the final song version for the Reels in Moscow"}}
	b := ChunkNotes{Decisions: []string{"use the final song version for the reels in Moscow."}}
	if got := mergeLines(t, a, b).Decisions; len(got) != 1 {
		t.Fatalf("decisions = %q, want one", got)
	}
}

// Key numbers are never fuzzy-merged: only a line equal after normalization is
// a repeat.
// Mutation: internal/meeting/notes.go MergeChunks, call dedupeLines for
// n.Numbers with `true` -> RED.
func TestMergeNumbersOnlyExactAfterNormalization(t *testing.T) {
	a := ChunkNotes{Numbers: []string{"Launch budget is about 5 thousand dollars for the ads and the photographer", "Shoot day: June 3"}}
	b := ChunkNotes{Numbers: []string{"Launch budget is about 5 thousand dollars for the ads and the photographers", "shoot day: june 3.", "Pay rate 500 dollars per hour for the editor", "Pay rate 700 dollars per hour for the editor"}}
	got := mergeLines(t, a, b).Numbers
	if len(got) != 5 || got[1] != "Shoot day: June 3" {
		t.Fatalf("numbers = %q, want the near-miss kept, the exact repeat (case, punctuation) merged", got)
	}
}

// One person's name in two scripts is one owner, and the recorder's own name
// takes the speaker label.
// Mutation: internal/meeting/notes.go sameOwner, replace `foldName(a) ==
// foldName(b)` with `strings.EqualFold(a, b)` -> RED.
func TestMergeFoldsSpellingsOfOneName(t *testing.T) {
	for _, pair := range [][2]string{{"Анатолий", "Anatoly"}, {"Anatoliy", "Анатолий"}, {"Фатема", "Fatema"}, {"Zoë", "ZOE"}} {
		a := ChunkNotes{ActionItems: []ActionItem{{Who: pair[0], What: "send the final report to the client today"}}}
		b := ChunkNotes{ActionItems: []ActionItem{{Who: pair[1], What: "send the final report to the client"}}}
		got := MergeChunks([]ChunkNotes{a, b}, Labels{Me: "Me", Them: "Them"}).ActionItems
		if len(got) != 1 || got[0].Who != pair[0] {
			t.Errorf("%v: items = %+v, want one task keeping the first spelling", pair, got)
		}
	}
}

// The recorder's own name in another spelling becomes the label.
// Mutation: internal/meeting/notes.go dedupeActions, delete the line
// `a.Who = canonicalOwner(a.Who, l)` -> RED.
func TestMergeMapsSpellingsOfMeToTheLabel(t *testing.T) {
	a := ChunkNotes{ActionItems: []ActionItem{{Who: "Анатолий", What: "send the final report to the client"}, {Who: "Fatema", What: "book the venue"}}}
	got := MergeChunks([]ChunkNotes{a}, Labels{Me: "Anatoly", Them: "Собеседник"}).ActionItems
	if len(got) != 2 || got[0].Who != "Anatoly" || got[1].Who != "Fatema" {
		t.Fatalf("items = %+v, want Me spelled as the label and Fatema left alone", got)
	}
}

// A group call: three different far-side people keep their own names and
// tasks, and nobody is folded into the "them" label or into another name.
// Mutation: internal/meeting/notes.go sameOwner, replace the body with
// `return true` -> RED.
func TestMergeKeepsDistinctNamedOwnersApart(t *testing.T) {
	task := "send the final report to the client"
	a := ChunkNotes{ActionItems: []ActionItem{{Who: "Fatema", What: task}, {Who: "Imad", What: task}, {Who: "Bob", What: task}}}
	b := ChunkNotes{ActionItems: []ActionItem{{Who: "Ann", What: task}, {Who: "Anna", What: task}, {Who: "Фатема", What: task}}}
	got := MergeChunks([]ChunkNotes{a, b}, Labels{Me: "Anatoly", Them: "Собеседник"}).ActionItems
	var who []string
	for _, it := range got {
		who = append(who, it.Who)
	}
	if strings.Join(who, ",") != "Fatema,Imad,Bob,Ann,Anna" {
		t.Fatalf("owners = %v, want five distinct people (Фатема folds into Fatema)", who)
	}
}

// An unstated owner joins the named copy; two named people do not join.
func TestMergeUnstatedOwnerJoinsTheNamedCopy(t *testing.T) {
	a := ChunkNotes{ActionItems: []ActionItem{{Who: "Bob", What: "send the final report to the client"}}}
	b := ChunkNotes{ActionItems: []ActionItem{{What: "send the final report to the client"}}}
	got := MergeChunks([]ChunkNotes{a, b}, Labels{}).ActionItems
	if len(got) != 1 || got[0].Who != "Bob" {
		t.Fatalf("items = %+v", got)
	}
}

func TestMergeKeepsTasksThatDifferByANumberOrAName(t *testing.T) {
	a := ChunkNotes{ActionItems: []ActionItem{{What: "pay Bob 500 dollars for the shoot"}, {What: "order 10 prints for the gallery"}}}
	b := ChunkNotes{ActionItems: []ActionItem{{What: "pay Ann 500 dollars for the shoot"}, {What: "order 12 prints for the gallery"}}}
	if got := mergeLines(t, a, b).ActionItems; len(got) != 4 {
		t.Fatalf("items = %+v, want 4", got)
	}
}

// Two stated, different dates are two tasks.
// Mutation: internal/meeting/notes.go sameTask, delete the `When` check
// (the `if !isUnstated(a.When) && ...` block) -> RED.
func TestMergeKeepsTasksWithDifferentStatedDates(t *testing.T) {
	a := ChunkNotes{ActionItems: []ActionItem{{Who: "Anatoly", What: "send the report to the client", When: "Monday"}}}
	b := ChunkNotes{ActionItems: []ActionItem{{Who: "Anatoly", What: "send the report to the client", When: "Friday"}}}
	got := mergeLines(t, a, b).ActionItems
	if len(got) != 2 || got[0].When != "Monday" || got[1].When != "Friday" {
		t.Fatalf("items = %+v, want both dates kept", got)
	}
}

func TestChunkSkipsEmptyPiecesAndGuardsALimitOfZero(t *testing.T) {
	text := "\n" + strings.Repeat("a", 30) + "\n"
	for _, c := range Chunk(text, 10) {
		if strings.TrimSpace(c) == "" {
			t.Fatalf("empty chunk among %q", Chunk(text, 10))
		}
	}
	for _, limit := range []int{0, -5} {
		if got := Chunk("[0:01] Me: hi\n", limit); len(got) != 1 {
			t.Fatalf("limit %d must fall back to ChunkChars, got %q", limit, got)
		}
	}
}

// Every piece of a cut turn says who speaks.
func TestChunkRepeatsTheSpeakerPrefixOnContinuationPieces(t *testing.T) {
	const prefix = "[12:03] Anatoly: "
	line := prefix + strings.Repeat("слово ", 40)
	pieces := Chunk(line+"\n", 100)
	if len(pieces) < 3 {
		t.Fatalf("only %d pieces", len(pieces))
	}
	var body strings.Builder
	for i, p := range pieces {
		if runeLen(p) > 100 {
			t.Fatalf("piece %d is %d characters", i, runeLen(p))
		}
		if i > 0 {
			if !strings.HasPrefix(p, prefix) {
				t.Fatalf("piece %d has no speaker prefix: %q", i, p)
			}
			p = strings.TrimPrefix(p, prefix)
		}
		body.WriteString(p)
	}
	if body.String() != line {
		t.Fatal("cutting a turn lost or reordered text")
	}
}

// blockingChat never answers until its context ends.
type blockingChat struct {
	mu    sync.Mutex
	calls int
}

func (b *blockingChat) Complete(ctx context.Context, _ Request) (string, error) {
	b.mu.Lock()
	b.calls++
	b.mu.Unlock()
	<-ctx.Done()
	return "", ctx.Err()
}

func TestComposeBoundsEachModelCallWithADeadline(t *testing.T) {
	f := &blockingChat{}
	start := time.Now()
	_, err := Composer{Chat: f, CallTimeout: 50 * time.Millisecond}.
		Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "en")
	if !errors.Is(err, ErrNoNotes) {
		t.Fatalf("err = %v, want ErrNoNotes after the deadline", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("the call deadline did not fire")
	}
	if f.calls != 1 {
		t.Fatalf("calls = %d: a call that used its whole deadline must not be retried", f.calls)
	}
	if callTimeout < 30*time.Minute {
		t.Fatalf("default call timeout %v is too short for a slow CPU", callTimeout)
	}
}

func TestComposeBacksOffBeforeRetryingABusyServer(t *testing.T) {
	good := replyJSON(t, ChunkNotes{Summary: "s"})
	for name, first := range map[string]error{
		"503":     &StatusError{Code: 503},
		"refused": fmt.Errorf("dial tcp: %w", syscall.ECONNREFUSED),
	} {
		f := &fakeChat{errs: []error{first}, replies: []string{"", good}}
		start := time.Now()
		got, err := Composer{Chat: f, RetryDelay: 80 * time.Millisecond}.
			Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "en")
		if err != nil || got.Summary != "s" || len(f.reqs) != 2 {
			t.Fatalf("%s: notes %+v, err %v, calls %d: the retry after the delay must succeed", name, got, err, len(f.reqs))
		}
		if time.Since(start) < 80*time.Millisecond {
			t.Fatalf("%s: retried after %v, before the 80ms backoff", name, time.Since(start))
		}
	}
}

func TestComposeDoesNotBackOffAfterAParseError(t *testing.T) {
	good := replyJSON(t, ChunkNotes{Summary: "s"})
	f := &fakeChat{replies: []string{"{broken", good}}
	start := time.Now()
	got, err := Composer{Chat: f, RetryDelay: 10 * time.Second}.
		Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "en")
	if err != nil || got.Summary != "s" {
		t.Fatalf("notes %+v, err %v", got, err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("a parse error waited out the busy-server backoff")
	}
}

// Valid JSON with nothing in it is a failed answer: retried, then skipped.
// Mutation: internal/meeting/notes.go chunk, replace `!out.empty()` with
// `true` -> RED.
func TestComposeTreatsAnAllEmptyAnswerAsAFailure(t *testing.T) {
	empty := replyJSON(t, ChunkNotes{})
	f := &fakeChat{replies: []string{empty, empty}}
	_, err := Composer{Chat: f}.Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "en")
	if !errors.Is(err, ErrNoNotes) || len(f.reqs) != 2 {
		t.Fatalf("err = %v after %d calls, want ErrNoNotes after a retry", err, len(f.reqs))
	}
	good := replyJSON(t, ChunkNotes{Summary: "s"})
	f = &fakeChat{replies: []string{empty, good}}
	got, err := Composer{Chat: f}.Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "en")
	if err != nil || got.Summary != "s" {
		t.Fatalf("the retry after an empty answer must be used: %+v, %v", got, err)
	}
}

// A merge call cut off at the token limit leaves the joined partial summaries.
func TestComposeKeepsPartialSummariesWhenTheMergeCallIsCutOff(t *testing.T) {
	text := strings.Repeat("[0:01] Me: "+strings.Repeat("word ", 30)+"\n", 300)
	n := len(Chunk(text, ChunkChars))
	f := &fakeChat{}
	for i := 0; i < n; i++ {
		f.replies = append(f.replies, replyJSON(t, ChunkNotes{Summary: fmt.Sprintf("part %d summary", i)}))
	}
	f.replies = append(f.replies, "a cut-off merged sum")
	f.errs = make([]error, n+1)
	f.errs[n] = ErrTruncated
	got, err := Composer{Chat: f}.Compose(context.Background(), text, Labels{}, "en")
	if err != nil || !strings.Contains(got.Summary, "part 0 summary") || strings.Contains(got.Summary, "cut-off") {
		t.Fatalf("summary = %q, err %v, want the joined partial summaries", got.Summary, err)
	}
}
