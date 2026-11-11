package meeting

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// The model answers a map step with a chunkAnswer. It is a claim about the transcript, not a fact: notes() checks it
// against the chunk's own text in code and only then produces the ChunkNotes the rest of the package works with. The
// stored notes keep their old shape (decisions, action_items, open_questions) so notes.json written before this
// existed still loads and renders; the model's evidence is kept beside them with omitempty.

// Owner evidence: why the model says this person will do the task.
const (
	evSelfCommit      = "self_commit"       // the owner said they will do it
	evAddressedByName = "addressed_by_name" // a request addressed to the owner by name
	evAcceptedRequest = "accepted_request"  // the owner agreed to a request made to them
	evUnstated        = "unstated"          // the transcript does not say who will do it
)

var ownerEvidence = []string{evSelfCommit, evAddressedByName, evAcceptedRequest, evUnstated}

// Point statuses.
const (
	statusDecided = "decided"
	statusOpen    = "open"
)

const (
	// minQuoteTokens: a one-word quote is no evidence, any common word occurs in a 16k-character chunk.
	minQuoteTokens = 2
	// maxQuoteRunes caps a stored quote; a quote is a phrase, not a paragraph.
	maxQuoteRunes = 300
)

// modelAction is one task as the model reports it.
type modelAction struct {
	What          string `json:"what"`
	Owner         string `json:"owner"`
	RequestedBy   string `json:"requested_by"`
	OwnerEvidence string `json:"owner_evidence"`
	Quote         string `json:"quote"`
	When          string `json:"when"`
}

// Point is one thing the meeting discussed: Status decided needs a Quote, the words that show the agreement.
type Point struct {
	Text   string `json:"text"`
	Status string `json:"status"`
	Quote  string `json:"quote"`
}

// chunkAnswer is the reply of a map step.
type chunkAnswer struct {
	Summary     string        `json:"summary"`
	Points      []Point       `json:"points"`
	ActionItems []modelAction `json:"action_items"`
	Numbers     []string      `json:"numbers"`
}

func (a chunkAnswer) empty() bool {
	return strings.TrimSpace(a.Summary) == "" && len(a.Points) == 0 && len(a.ActionItems) == 0 && len(a.Numbers) == 0
}

// notes checks the answer against the chunk's text and returns the notes it supports. An owner is kept only when the
// model's quote occurs in the text and its evidence is not "unstated"; a decision is kept only with an agreement
// quote that occurs in the text, else it is an open point. A task never needs evidence to stay: an empty owner is
// better than a confident wrong one.
func (a chunkAnswer) notes(chunkText string) ChunkNotes {
	idx := newTextIndex(chunkText)
	out := ChunkNotes{Summary: a.Summary, Numbers: a.Numbers}
	for _, p := range a.Points {
		claimed := strings.ToLower(strings.TrimSpace(p.Status))
		p.Text = strings.TrimSpace(p.Text)
		if p.Text == "" {
			continue
		}
		p.Quote = idx.verified(p.Quote)
		p.Status = statusOpen
		if claimed == statusDecided && p.Quote != "" {
			p.Status = statusDecided
		}
		out.Points = append(out.Points, p)
	}
	out.Decisions, out.OpenQuestions = splitPoints(out.Points)
	for _, m := range a.ActionItems {
		out.ActionItems = append(out.ActionItems, m.checked(idx))
	}
	return out
}

// checked is the model's task as a stored ActionItem. The owner survives only when the evidence names a reason and
// the quote shows it; a request never makes its asker the owner.
func (m modelAction) checked(idx textIndex) ActionItem {
	a := ActionItem{
		Who: strings.TrimSpace(m.Owner), What: strings.TrimSpace(m.What), When: m.When,
		RequestedBy: strings.TrimSpace(m.RequestedBy), Quote: idx.verified(m.Quote),
	}
	if isUnstated(a.Who) {
		a.Who = ""
	}
	if isUnstated(a.RequestedBy) {
		a.RequestedBy = ""
	}
	ev := strings.ToLower(strings.TrimSpace(m.OwnerEvidence))
	switch {
	case !validEvidence(ev) || ev == evUnstated:
		a.Who = ""
	case a.Quote == "":
		a.Who = "" // the transcript does not hold the words the model says show it
	case ev != evSelfCommit && a.RequestedBy != "" && foldName(a.Who) == foldName(a.RequestedBy):
		a.Who = "" // "owner" is the one who asked: the model swapped the roles
	}
	if a.Who != "" {
		a.OwnerEvidence = ev
	} else {
		a.OwnerEvidence = evUnstated
	}
	return a
}

func validEvidence(ev string) bool {
	for _, v := range ownerEvidence {
		if ev == v {
			return true
		}
	}
	return false
}

// splitPoints is the stored decisions and open questions of a chunk, in the order the model gave them.
func splitPoints(pts []Point) (decisions, open []string) {
	for _, p := range pts {
		if p.Status == statusDecided {
			decisions = append(decisions, p.Text)
		} else {
			open = append(open, p.Text)
		}
	}
	return decisions, open
}

// textIndex is a chunk's text as lower-cased word tokens, to find a quote in. The match is exact on words and
// forgiving on form only: case, spacing, punctuation and ё/е do not matter; a word changed, added or dropped does.
// There is no fuzzy or paraphrase allowance: a similarity threshold would let a model that invented a sentence
// through whenever it borrowed enough words, and the failure of a miss is only an empty owner.
type textIndex struct{ tokens []string }

func newTextIndex(text string) textIndex { return textIndex{tokens: quoteTokens(text)} }

func quoteTokens(s string) []string {
	return tokens(strings.NewReplacer("ё", "е", "Ё", "е").Replace(strings.ToLower(s)))
}

// has: the quote has at least minQuoteTokens words and they occur in the text next to each other, in order.
func (x textIndex) has(quote string) bool {
	q := quoteTokens(quote)
	if len(q) < minQuoteTokens {
		return false
	}
	for i := 0; i+len(q) <= len(x.tokens); i++ {
		if x.tokens[i] == q[0] && equalTokens(x.tokens[i:i+len(q)], q) {
			return true
		}
	}
	return false
}

func equalTokens(a, b []string) bool {
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// verified is the quote as it is stored: "" unless it occurs in the text, else one inline line, cut to
// maxQuoteRunes and cleaned like every model string (cleanLine). It is stored escaped, so a reader must not clean it
// again; notes.md does not show it.
func (x textIndex) verified(quote string) string {
	quote = strings.Join(strings.Fields(quote), " ")
	if !x.has(quote) {
		return ""
	}
	if r := []rune(quote); len(r) > maxQuoteRunes {
		quote = string(r[:maxQuoteRunes])
	}
	return cleanLine(quote)
}

// ---- merging points across chunks ----

// samePoint: two points are one by words alone, the way the lists were deduplicated before they were joined.
func samePoint(a, b string) bool {
	return normKey(a) == normKey(b) || (voices.WordOverlap(a, b) >= similarLine && !factsDiffer(a, b))
}

// numbersConflict: both lines state numbers and the numbers differ. A point that gains a number between chunks
// ("what budget?" then "budget 700") is still one point; "budget 500" and "budget 700" are two.
func numbersConflict(a, b string) bool {
	na, nb := numbersOf(a), numbersOf(b)
	return na != "" && nb != "" && na != nb
}

type pointRef struct {
	chunk int // index of the part in the slice MergeChunks was given: later is later in the meeting
	Point
}

// pointsOf is the points of one part. A part without Points (notes built by hand, or a test) contributes its
// Decisions and OpenQuestions as points.
func pointsOf(p ChunkNotes) []Point {
	if len(p.Points) > 0 {
		return p.Points
	}
	var out []Point
	for _, d := range p.Decisions {
		out = append(out, Point{Text: d, Status: statusDecided})
	}
	for _, q := range p.OpenQuestions {
		out = append(out, Point{Text: q, Status: statusOpen})
	}
	return out
}

func flattenPoints(parts []ChunkNotes) []pointRef {
	var out []pointRef
	for i, p := range parts {
		for _, pt := range pointsOf(p) {
			if strings.TrimSpace(pt.Text) != "" {
				pt.Text = strings.TrimSpace(pt.Text)
				out = append(out, pointRef{chunk: i, Point: pt})
			}
		}
	}
	return out
}

// pointPair is two indices into flattenPoints that the reduce call says are one point.
type pointPair struct {
	A int `json:"a"`
	B int `json:"b"`
}

// mergePoints returns the decided and open lists of the meeting. Points that are one (by words, or because the
// reduce call paired them) form a group; a group has exactly one status: the one from the latest part that mentions
// it, and open when that part holds the same point both ways. Each group is written once, in the words of the first
// point that has the winning status, at that point's place.
func mergePoints(pts []pointRef, pairs []pointPair) (decided, open []string) {
	parent := make([]int, len(pts))
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(i int) int {
		for parent[i] != i {
			parent[i] = parent[parent[i]]
			i = parent[i]
		}
		return i
	}
	union := func(i, j int) {
		if ri, rj := find(i), find(j); ri != rj {
			parent[max(ri, rj)] = min(ri, rj)
		}
	}
	for i := range pts {
		for j := 0; j < i; j++ {
			if samePoint(pts[i].Text, pts[j].Text) {
				union(i, j)
			}
		}
	}
	for _, p := range pairs {
		if p.A < 0 || p.B < 0 || p.A >= len(pts) || p.B >= len(pts) || p.A == p.B {
			continue
		}
		// Two points of one part were listed apart by the model on purpose.
		if pts[p.A].chunk == pts[p.B].chunk || numbersConflict(pts[p.A].Text, pts[p.B].Text) {
			continue
		}
		union(p.A, p.B)
	}
	groups := map[int][]int{}
	var roots []int
	for i := range pts {
		r := find(i)
		if _, ok := groups[r]; !ok {
			roots = append(roots, r)
		}
		groups[r] = append(groups[r], i)
	}
	type rep struct {
		idx    int
		status string
	}
	var reps []rep
	for _, r := range roots {
		g := groups[r]
		last := 0
		for _, i := range g {
			last = max(last, pts[i].chunk)
		}
		status := statusDecided
		for _, i := range g {
			if pts[i].chunk == last && pts[i].Status != statusDecided {
				status = statusOpen // the latest part is not sure; neither are the notes
			}
		}
		for _, i := range g {
			if (pts[i].Status == statusDecided) == (status == statusDecided) {
				reps = append(reps, rep{i, status})
				break
			}
		}
	}
	sort.Slice(reps, func(i, j int) bool { return reps[i].idx < reps[j].idx })
	for _, r := range reps {
		if r.status == statusDecided {
			decided = append(decided, pts[r.idx].Text)
		} else {
			open = append(open, pts[r.idx].Text)
		}
	}
	return decided, open
}

// ---- the reduce call ----

const (
	// maxReducePoints bounds the reduce prompt: a meeting with more points than this keeps the code path alone.
	maxReducePoints = 120
	maxReduceText   = 200
)

func pairSchema() map[string]any {
	num := map[string]any{"type": "integer"}
	return map[string]any{
		"type": "object",
		"properties": map[string]any{"same": map[string]any{"type": "array", "items": map[string]any{
			"type":                 "object",
			"properties":           map[string]any{"a": num, "b": num},
			"required":             []string{"a", "b"},
			"additionalProperties": false,
		}}},
		"required":             []string{"same"},
		"additionalProperties": false,
	}
}

func pairSystem() string {
	return "You compare the points of one meeting, written from different parts of its transcript. Each line is " +
		"\"[id] (part N, decided|open) text\". Output the pairs of ids that state the SAME point: the same topic and " +
		"the same name, number and subject, said again or reworded, or a point left open in an earlier part and settled " +
		"in a later one. Pair points from different parts only. Never pair points that differ in a name, a number or " +
		"what is decided. If no points are the same, output an empty list. Output only ids. " + untrustedRule
}

// pairPoints asks the model, once, which points of different parts are one. It is skipped (no pairs, no error) when
// it cannot change the notes: fewer than two groups of points after the words-only merge, or points from a single
// part, or too many points for one prompt. A failure is returned for Compose to log and drop.
func (c Composer) pairPoints(ctx context.Context, parts []ChunkNotes) ([]pointPair, error) {
	pts := flattenPoints(parts)
	if len(pts) < 2 || len(pts) > maxReducePoints {
		return nil, nil
	}
	chunks := map[int]bool{}
	for _, p := range pts {
		chunks[p.chunk] = true
	}
	if len(chunks) < 2 {
		return nil, nil
	}
	if d, o := mergePoints(pts, nil); len(d)+len(o) < 2 {
		return nil, nil
	}
	var b strings.Builder
	for i, p := range pts {
		fmt.Fprintf(&b, "[%d] (part %d, %s) %s\n", i, p.chunk+1, p.Status, truncateRunes(strings.Join(strings.Fields(p.Text), " "), maxReduceText))
	}
	if c.Before != nil {
		if err := c.Before(ctx); err != nil {
			return nil, err
		}
	}
	raw, err := c.call(ctx, Request{System: pairSystem(), User: b.String(), Schema: pairSchema(), MaxTokens: 600})
	if err != nil {
		return nil, err
	}
	var out struct {
		Same []pointPair `json:"same"`
	}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, err
	}
	return out.Same, nil
}

func truncateRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
