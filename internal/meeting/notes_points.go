package meeting

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

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
	// maxQuoteRunes caps a stored quote; a quote is a phrase, not a paragraph. The schema asks for no more
	// (maxLength), and the code does not trust the grammar: a quote over maxQuoteBytes or maxQuoteTokens is refused
	// before any matching.
	maxQuoteRunes  = 300
	maxQuoteBytes  = 4 * maxQuoteRunes
	maxQuoteTokens = 60
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

// textIndex is a chunk's spoken text as lower-cased word tokens, one list per turn, to find a quote in. A quote must
// lie inside ONE turn's words: the "[m:ss] Name: " prefix is not spoken text and a quote cannot run from one turn into
// the next. The match is exact on words and forgiving on form only: Unicode normalization (NFKC), case, spacing,
// punctuation and ё/е do not matter; a word changed, added or dropped does. There is no fuzzy or paraphrase allowance:
// a similarity threshold would let a model that invented a sentence through whenever it borrowed enough words, and the
// failure of a miss is only an empty owner.
type textIndex struct {
	turns [][]string
	at    map[string][]tokenPos // where each word occurs
}

type tokenPos struct{ turn, pos int }

func newTextIndex(text string) textIndex {
	x := textIndex{at: map[string][]tokenPos{}}
	for _, line := range strings.Split(text, "\n") {
		line = turnPrefix.ReplaceAllString(line, "")
		toks := quoteTokens(line)
		if len(toks) == 0 {
			continue
		}
		for pos, w := range toks {
			x.at[w] = append(x.at[w], tokenPos{len(x.turns), pos})
		}
		x.turns = append(x.turns, toks)
	}
	return x
}

func quoteTokens(s string) []string {
	return tokens(strings.NewReplacer("ё", "е").Replace(strings.ToLower(norm.NFKC.String(s))))
}

// has: the quote has between minQuoteTokens and maxQuoteTokens words and they occur next to each other, in order,
// inside one turn. An oversized quote is refused before it is tokenized: it is not a phrase, and the model's string
// is not trusted to be small.
func (x textIndex) has(quote string) bool {
	if len(quote) > maxQuoteBytes {
		return false
	}
	q := quoteTokens(quote)
	if len(q) < minQuoteTokens || len(q) > maxQuoteTokens {
		return false
	}
	for _, at := range x.at[q[0]] {
		turn := x.turns[at.turn]
		if at.pos+len(q) <= len(turn) && equalTokens(turn[at.pos:at.pos+len(q)], q) {
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
	if len(quote) > maxQuoteBytes {
		return ""
	}
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

// subsetKeys: every key of a is in b.
func subsetKeys(a, b map[string]bool) bool {
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

func numberSet(s string) map[string]bool {
	m := map[string]bool{}
	for _, n := range numberRun.FindAllString(s, -1) {
		m[n] = true
	}
	return m
}

// nameSet is the proper names of a point: capitalized words that are not its first word (a sentence start is
// capitalized anyway).
func nameSet(s string) map[string]bool {
	m := map[string]bool{}
	for i, w := range tokens(s) {
		r, _ := utf8.DecodeRuneInString(w)
		if i > 0 && utf8.RuneCountInString(w) >= 2 && unicode.IsUpper(r) {
			m[strings.ToLower(w)] = true
		}
	}
	return m
}

// disagree: each set has something the other lacks ("Bob" and "Ann", "500" and "700"). A set that only grows
// ("what budget?" then "budget 700", "who does it?" then "Daphne does it") is the same point settled.
func disagree(a, b map[string]bool) bool { return !subsetKeys(a, b) && !subsetKeys(b, a) }

// pairFactsOK is the code's check of a claim that two points are one, whoever made the claim (the words rule or the
// reduce call): their numbers and proper names must not disagree, and two points that differ only in their first
// word ("Paris office", "Rome office") are two. A paraphrase changes more than that.
func pairFactsOK(a, b string) bool {
	if disagree(numberSet(a), numberSet(b)) || disagree(nameSet(a), nameSet(b)) {
		return false
	}
	ta, tb := tokens(a), tokens(b)
	if len(ta) > 1 && len(ta) == len(tb) && !strings.EqualFold(ta[0], tb[0]) {
		same := true
		for i := 1; i < len(ta); i++ {
			same = same && strings.EqualFold(ta[i], tb[i])
		}
		return !same
	}
	return true
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

// groupPoints groups the points that are one. A link (by words, or a pair from the reduce call) joins two groups only
// when EVERY point of one agrees with EVERY point of the other under pairFactsOK, so a chain a~b, b~c never
// puts a and c together when they disagree. Chains are refused rather than limited to one partner: the check is on
// facts, which is what makes two points different, and it needs no ordering of the model's pairs. Groups come back
// in order of their first point.
func groupPoints(pts []pointRef, pairs []pointPair) [][]int {
	group := make([]int, len(pts)) // point -> group id
	members := map[int][]int{}
	for i := range pts {
		group[i] = i
		members[i] = []int{i}
	}
	join := func(i, j int) {
		gi, gj := group[i], group[j]
		if gi == gj {
			return
		}
		for _, x := range members[gi] {
			for _, y := range members[gj] {
				if !pairFactsOK(pts[x].Text, pts[y].Text) {
					return
				}
			}
		}
		keep, drop := min(gi, gj), max(gi, gj)
		for _, y := range members[drop] {
			group[y] = keep
		}
		members[keep] = append(members[keep], members[drop]...)
		delete(members, drop)
	}
	for i := range pts {
		for j := 0; j < i; j++ {
			if samePoint(pts[i].Text, pts[j].Text) {
				join(i, j)
			}
		}
	}
	for _, p := range pairs {
		if p.A < 0 || p.B < 0 || p.A >= len(pts) || p.B >= len(pts) || p.A == p.B {
			continue
		}
		// Two points of one part were listed apart by the model on purpose.
		if pts[p.A].chunk == pts[p.B].chunk {
			continue
		}
		join(p.A, p.B)
	}
	var out [][]int
	for _, m := range members {
		sort.Ints(m)
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i][0] < out[j][0] })
	return out
}

// groupStatus is the status a group settles on: the one from the latest part that mentions it, open when that part
// holds the same point both ways.
func groupStatus(pts []pointRef, g []int) string {
	last := 0
	for _, i := range g {
		last = max(last, pts[i].chunk)
	}
	for _, i := range g {
		if pts[i].chunk == last && pts[i].Status != statusDecided {
			return statusOpen // the latest part is not sure; neither are the notes
		}
	}
	return statusDecided
}

// groupRep is the point a group is written as: the first one that has the group's status.
func groupRep(pts []pointRef, g []int, status string) int {
	for _, i := range g {
		if (pts[i].Status == statusDecided) == (status == statusDecided) {
			return i
		}
	}
	return g[0]
}

// mergePoints returns the decided and open lists of the meeting. A group has exactly one status (groupStatus) and
// is written once, in the words of groupRep, at that point's place.
func mergePoints(pts []pointRef, pairs []pointPair) (decided, open []string) {
	type rep struct {
		idx    int
		status string
	}
	var reps []rep
	for _, g := range groupPoints(pts, pairs) {
		st := groupStatus(pts, g)
		reps = append(reps, rep{groupRep(pts, g, st), st})
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
	// maxReducePoints bounds one reduce prompt; maxReduceCalls bounds the calls of a meeting.
	maxReducePoints = 120
	maxReduceCalls  = 3
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

// reduceBatches lists, for the reduce call(s), the points that can still change the notes: one per group of the
// words-only merge, the open ones (a question left unsettled) and the decided ones (what may settle or reopen it).
// Two settled-the-same-way groups are never sent against each other. Up to maxReducePoints they go in one call. Over
// that, the open groups are split into at most maxReduceCalls slices and each slice goes with the decided groups
// that share the most words with it, filling the prompt to maxReducePoints; whatever does not fit keeps the words-only merge. So a
// meeting costs at most maxReduceCalls calls, each at most maxReducePoints lines.
func reduceBatches(pts []pointRef) [][]int {
	var open, decided []int
	for _, g := range groupPoints(pts, nil) {
		st := groupStatus(pts, g)
		if st == statusOpen {
			open = append(open, groupRep(pts, g, st))
		} else {
			decided = append(decided, groupRep(pts, g, st))
		}
	}
	if len(open) == 0 || len(open)+len(decided) < 2 {
		return nil
	}
	if len(open)+len(decided) <= maxReducePoints {
		return [][]int{sortedUnion(open, decided)}
	}
	per := (len(open) + maxReduceCalls - 1) / maxReduceCalls
	per = min(per, maxReducePoints/2)
	var out [][]int
	for lo := 0; lo < len(open) && len(out) < maxReduceCalls; lo += per {
		sl := open[lo:min(lo+per, len(open))]
		near := append([]int(nil), decided...)
		score := map[int]float64{}
		for _, d := range near {
			for _, o := range sl {
				score[d] = max(score[d], voices.WordOverlap(pts[d].Text, pts[o].Text))
			}
		}
		sort.SliceStable(near, func(a, b int) bool { return score[near[a]] > score[near[b]] })
		near = near[:min(len(near), maxReducePoints-len(sl))]
		out = append(out, sortedUnion(sl, near))
	}
	return out
}

func sortedUnion(a, b []int) []int {
	out := append(append([]int(nil), a...), b...)
	sort.Ints(out)
	return out
}

// pairPoints asks the model which points of different parts are one: at most maxReduceCalls calls (usually one),
// none when nothing can change (see reduceBatches). A failed batch is skipped; the first error is returned beside
// the pairs the other batches gave, for Compose to log. The pairs are only claims: groupPoints checks them.
func (c Composer) pairPoints(ctx context.Context, parts []ChunkNotes) ([]pointPair, error) {
	pts := flattenPoints(parts)
	chunks := map[int]bool{}
	for _, p := range pts {
		chunks[p.chunk] = true
	}
	if len(pts) < 2 || len(chunks) < 2 {
		return nil, nil
	}
	var pairs []pointPair
	var firstErr error
	for _, batch := range reduceBatches(pts) {
		got, err := c.pairBatch(ctx, pts, batch)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		pairs = append(pairs, got...)
	}
	return pairs, firstErr
}

func (c Composer) pairBatch(ctx context.Context, pts []pointRef, batch []int) ([]pointPair, error) {
	var b strings.Builder
	for _, i := range batch {
		p := pts[i]
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
	in := map[int]bool{}
	for _, i := range batch {
		in[i] = true
	}
	var ok []pointPair
	for _, p := range out.Same {
		if in[p.A] && in[p.B] { // an id the prompt did not list is not a claim about this prompt
			ok = append(ok, p)
		}
	}
	return ok, nil
}

func truncateRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
