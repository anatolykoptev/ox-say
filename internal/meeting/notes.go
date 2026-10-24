package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// ChunkChars is the size of one map step's transcript: about 16k characters,
// the size the notes spike measured with -c 16384 (a call of 5k prompt tokens
// leaves the context room for a 3k-token answer).
const ChunkChars = 16000

const (
	// similarAction and similarLine: word overlap at which two items are one.
	similarAction = 0.6
	similarLine   = 0.7
	// summaryBudget caps the partial summaries sent to the merge call.
	summaryBudget = 12000
	maxAnswer     = 3000
)

// ActionItem is one task; Who and When are empty when the transcript names
// neither.
type ActionItem struct {
	Who  string `json:"who"`
	What string `json:"what"`
	When string `json:"when"`
}

// ChunkNotes is what the model returns for one chunk (and, merged, the notes).
type ChunkNotes struct {
	Summary       string       `json:"summary"`
	Decisions     []string     `json:"decisions"`
	ActionItems   []ActionItem `json:"action_items"`
	OpenQuestions []string     `json:"open_questions"`
	Numbers       []string     `json:"numbers"`
}

// Notes are the finished notes. SkippedChunks lists the zero-based chunks the
// model failed on twice; the notes say so instead of looking complete.
type Notes struct {
	ChunkNotes
	SkippedChunks []int `json:"skipped_chunks,omitempty"`
}

// Chunk splits text into pieces of at most max characters, breaking only at
// line ends; one line longer than max is cut.
func Chunk(text string, max int) []string {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	var out []string
	var cur strings.Builder
	flush := func() {
		if cur.Len() > 0 {
			out = append(out, strings.TrimRight(cur.String(), "\n"))
			cur.Reset()
		}
	}
	for _, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		for runeLen(line) > max {
			flush()
			r := []rune(line)
			out = append(out, string(r[:max]))
			line = string(r[max:])
		}
		if runeLen(cur.String())+runeLen(line)+1 > max {
			flush()
		}
		cur.WriteString(line)
		cur.WriteByte('\n')
	}
	flush()
	return out
}

var unstated = map[string]bool{
	"": true, "not stated": true, "unknown": true, "n/a": true, "none": true, "-": true, "—": true,
	"не указано": true, "не указан": true, "не указана": true, "неизвестно": true,
}

func isUnstated(s string) bool { return unstated[strings.ToLower(strings.TrimSpace(s))] }

// MergeChunks joins the per-chunk notes and removes repeats in code: the same
// task found in two chunks, or twice in one, appears once, with the owner and
// date when either copy had them. Order is first appearance.
func MergeChunks(parts []ChunkNotes) Notes {
	var n Notes
	var summaries []string
	for _, p := range parts {
		if s := strings.TrimSpace(p.Summary); s != "" {
			summaries = append(summaries, s)
		}
		n.Decisions = append(n.Decisions, p.Decisions...)
		n.ActionItems = append(n.ActionItems, p.ActionItems...)
		n.OpenQuestions = append(n.OpenQuestions, p.OpenQuestions...)
		n.Numbers = append(n.Numbers, p.Numbers...)
	}
	n.Summary = strings.Join(summaries, "\n\n")
	n.Decisions = dedupeLines(n.Decisions)
	n.OpenQuestions = dedupeLines(n.OpenQuestions)
	n.Numbers = dedupeLines(n.Numbers)
	n.ActionItems = dedupeActions(n.ActionItems)
	return n
}

func dedupeLines(in []string) []string {
	var out []string
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		dup := false
		for _, o := range out {
			if voices.WordOverlap(s, o) >= similarLine {
				dup = true
				break
			}
		}
		if !dup {
			out = append(out, s)
		}
	}
	return out
}

func dedupeActions(in []ActionItem) []ActionItem {
	var out []ActionItem
	for _, a := range in {
		a.What = strings.TrimSpace(a.What)
		if a.What == "" {
			continue
		}
		merged := false
		for i, o := range out {
			if voices.WordOverlap(a.What, o.What) < similarAction || !sameOwner(a.Who, o.Who) {
				continue
			}
			if len(a.What) > len(o.What) {
				out[i].What = a.What
			}
			if isUnstated(o.Who) {
				out[i].Who = a.Who
			}
			if isUnstated(o.When) {
				out[i].When = a.When
			}
			merged = true
			break
		}
		if !merged {
			out = append(out, a)
		}
	}
	return out
}

// sameOwner: two owners agree when either is unstated or they are the same name.
func sameOwner(a, b string) bool {
	return isUnstated(a) || isUnstated(b) || strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b))
}

// Chat is the language model, behind the one call the notes need. Schema nil
// asks for free text.
type Chat interface {
	Complete(ctx context.Context, r Request) (string, error)
}

// Request is one chat call.
type Request struct {
	System, User string
	Schema       map[string]any
	MaxTokens    int
}

// ErrNoNotes: the model failed on every chunk.
var ErrNoNotes = errors.New("meeting: the notes model failed on every part of the transcript")

// chunkSchema is the answer shape of a map step; llama-server turns it into a
// grammar, so the reply is always parseable JSON of this shape.
func chunkSchema() map[string]any {
	str := map[string]any{"type": "string"}
	list := map[string]any{"type": "array", "items": str}
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"summary":   str,
			"decisions": list,
			"action_items": map[string]any{"type": "array", "items": map[string]any{
				"type":                 "object",
				"properties":           map[string]any{"who": str, "what": str, "when": str},
				"required":             []string{"who", "what", "when"},
				"additionalProperties": false,
			}},
			"open_questions": list,
			"numbers":        list,
		},
		"required":             []string{"summary", "decisions", "action_items", "open_questions", "numbers"},
		"additionalProperties": false,
	}
}

func chunkSystem(l Labels) string {
	return "You write meeting notes from one part of a transcript. Write every field in the same language as the transcript. " +
		"Use ONLY facts stated in the transcript; never invent names, numbers, dates or owners. " +
		fmt.Sprintf("The speakers are %q (the person who recorded the call) and %q (everyone else on the call); in \"who\" use these names, or a name said in the transcript. ", l.Me, l.Them) +
		"If the owner or the date of an action item is not stated, leave that field an empty string. " +
		"summary: 2-4 sentences. decisions: what was agreed. action_items: every task someone took on or was asked to do, one entry per task. " +
		"open_questions: questions left unanswered. numbers: key numbers, amounts and dates with what they refer to. Skip small talk. " +
		"Use empty lists when a part has nothing for a field."
}

const mergeSystem = "You merge partial meeting summaries into one summary of 3-5 lines. Write in the same language as the partial summaries. " +
	"Use ONLY facts present in them; never invent names, numbers, dates or owners. Output the summary text only."

// Composer runs the map-reduce. Before, when set, runs ahead of every model
// call: the daemon passes the dictation yield so notes never starve a user who
// is dictating.
type Composer struct {
	Chat   Chat
	Before func(ctx context.Context) error
	Log    *slog.Logger
}

// Compose writes the notes for the transcript text: one structured call per
// chunk, a dedupe in code, and one short call to merge the summaries.
func (c Composer) Compose(ctx context.Context, transcript string, l Labels) (Notes, error) {
	chunks := Chunk(transcript, ChunkChars)
	var parts []ChunkNotes
	var skipped []int
	for i, ch := range chunks {
		got, err := c.chunk(ctx, l, i, len(chunks), ch)
		if err != nil {
			if ctx.Err() != nil {
				return Notes{}, ctx.Err()
			}
			c.logf("notes: chunk failed twice", slog.Int("chunk", i), slog.Any("error", err))
			skipped = append(skipped, i)
			continue
		}
		parts = append(parts, got)
	}
	if len(parts) == 0 {
		return Notes{}, ErrNoNotes
	}
	n := MergeChunks(parts)
	n.SkippedChunks = skipped
	if len(parts) > 1 {
		n.Summary = c.mergeSummary(ctx, parts, n.Summary)
	}
	return n, nil
}

func (c Composer) chunk(ctx context.Context, l Labels, i, total int, text string) (ChunkNotes, error) {
	req := Request{
		System:    chunkSystem(l),
		User:      fmt.Sprintf("This is part %d of %d of a meeting transcript. Write the notes for this part only.\n\nTRANSCRIPT PART:\n%s", i+1, total, text),
		Schema:    chunkSchema(),
		MaxTokens: maxAnswer,
	}
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if c.Before != nil {
			if err := c.Before(ctx); err != nil {
				return ChunkNotes{}, err
			}
		}
		raw, err := c.Chat.Complete(ctx, req)
		if err == nil {
			var out ChunkNotes
			if err = json.Unmarshal([]byte(raw), &out); err == nil {
				return out, nil
			}
		}
		if ctx.Err() != nil {
			return ChunkNotes{}, ctx.Err()
		}
		lastErr = err
	}
	return ChunkNotes{}, lastErr
}

// mergeSummary asks the model for one short summary of the partial ones; on
// any failure the partial summaries stand as they are.
func (c Composer) mergeSummary(ctx context.Context, parts []ChunkNotes, fallback string) string {
	var b strings.Builder
	for i, p := range parts {
		s := strings.TrimSpace(p.Summary)
		if runeLen(b.String())+runeLen(s) > summaryBudget {
			break
		}
		fmt.Fprintf(&b, "--- PART %d ---\n%s\n\n", i+1, s)
	}
	if c.Before != nil && c.Before(ctx) != nil {
		return fallback
	}
	out, err := c.Chat.Complete(ctx, Request{System: mergeSystem, User: b.String(), MaxTokens: 800})
	out = strings.TrimSpace(out)
	if err != nil || out == "" || runeLen(out) > 2000 {
		return fallback
	}
	return out
}

func (c Composer) logf(msg string, args ...any) {
	if c.Log != nil {
		c.Log.Warn(msg, args...)
	}
}

// runeLen is utf8.RuneCountInString: chunk sizes count characters, the way the
// notes spike measured them, so Cyrillic is not charged twice.
func runeLen(s string) int { return utf8.RuneCountInString(s) }
