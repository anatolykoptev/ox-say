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
	lastPrefix := ""
	for _, line := range strings.Split(text, "\n") {
		prefix := turnPrefix.FindString(line)
		toks := quoteTokens(line[len(prefix):])
		if len(toks) == 0 {
			continue
		}
		// A line without a prefix goes on from the line before it (a turn that spans lines), and so does a line with
		// the same prefix as the one before (the pieces Chunk cuts an overlong line into): one utterance, one turn.
		if len(x.turns) > 0 && (prefix == "" || prefix == lastPrefix) {
			x.turns[len(x.turns)-1] = append(x.turns[len(x.turns)-1], toks...)
		} else {
			x.turns = append(x.turns, toks)
		}
		if prefix != "" {
			lastPrefix = prefix
		}
	}
	for t, toks := range x.turns {
		for pos, w := range toks {
			x.at[w] = append(x.at[w], tokenPos{t, pos})
		}
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

// samePoint: two points are one by words alone, the way the lists were deduplicated before they were joined. A
// restatement is one point; a reworded one is two, and a duplicate line is the price of never merging by guess.
func samePoint(a, b string) bool {
	return normKey(a) == normKey(b) || (voices.WordOverlap(a, b) >= similarLine && !factsDiffer(a, b))
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

// pointGroup is the restatements of one point. It has one status: the one from the latest part that mentions it, and
// open when that part holds the same point both ways. It is written once, as rep: the first member with that status.
type pointGroup struct {
	members []int
	status  string
	last    int // the latest part that mentions it
	rep     int
}

// buildGroups groups the points by words. Each point joins the first group whose first member it restates, in the
// order of the points: no chains, and the same input always gives the same groups.
func buildGroups(pts []pointRef) []pointGroup {
	var gs []pointGroup
	for i := range pts {
		placed := false
		for g := range gs {
			if samePoint(pts[i].Text, pts[gs[g].members[0]].Text) {
				gs[g].members = append(gs[g].members, i)
				placed = true
				break
			}
		}
		if !placed {
			gs = append(gs, pointGroup{members: []int{i}})
		}
	}
	for g := range gs {
		m := gs[g].members
		for _, i := range m {
			gs[g].last = max(gs[g].last, pts[i].chunk)
		}
		gs[g].status = statusDecided
		for _, i := range m {
			if pts[i].chunk == gs[g].last && pts[i].Status != statusDecided {
				gs[g].status = statusOpen // the latest part is not sure; neither are the notes
			}
		}
		gs[g].rep = m[0]
		for _, i := range m {
			if (pts[i].Status == statusDecided) == (gs[g].status == statusDecided) {
				gs[g].rep = i
				break
			}
		}
	}
	return gs
}

// settleClaim is the reduce call's answer for one open point: the decided points of later parts that settle it.
// It is a claim, checked by acceptSettles.
type settleClaim struct {
	Open    int   `json:"open"`
	Decided []int `json:"decided"`
}

// numberSet is the numbers in s.
func numberSet(s string) map[string]bool {
	m := map[string]bool{}
	for _, n := range numberRun.FindAllString(s, -1) {
		m[n] = true
	}
	return m
}

func subsetKeys(a, b map[string]bool) bool {
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

// capitalized lists the capitalized words of s; withFirst keeps the first word, which a sentence start capitalizes
// anyway. A word in capitals (API, QA, an emphasis) is an ordinary word here, not a name.
func capitalized(s string, withFirst bool) []string {
	var out []string
	for i, w := range tokens(s) {
		r, _ := utf8.DecodeRuneInString(w)
		if (i > 0 || withFirst) && utf8.RuneCountInString(w) >= 2 && unicode.IsUpper(r) && strings.ToUpper(w) != w {
			out = append(out, w)
		}
	}
	return out
}

func foldWord(w string) []rune {
	w = strings.NewReplacer("ё", "е").Replace(strings.ToLower(norm.NFKC.String(w)))
	w = strings.TrimSuffix(strings.TrimSuffix(w, "'s"), "’s")
	return []rune(w)
}

func isCyrillic(r []rune) bool {
	for _, c := range r {
		if !unicode.Is(unicode.Cyrillic, c) {
			return false
		}
	}
	return len(r) > 0
}

// ruEndings are the Russian case and gender endings, up to three letters, that stemRu takes off.
var ruEndings = map[string]bool{}

func init() {
	for _, e := range strings.Fields(`ами ями ого его ому ему ией ой ей ою ею ом ем ам ям ах ях ов ев ию ия ие ии ых их ый ий
		ая яя ое ее ую юю а я у ю е ы и о ь й`) {
		ruEndings[e] = true
	}
}

// stemRu is a Cyrillic word without its case ending, when at least three letters are left: Дашей, Даше, Дашу, Даша are
// "даш". A word with no such ending is its own stem. The names Мария (мар) and Марину (марин) stay two.
func stemRu(r []rune) string {
	for l := 3; l >= 1; l-- {
		if len(r)-l >= 3 && ruEndings[string(r[len(r)-l:])] {
			return string(r[:len(r)-l])
		}
	}
	return string(r)
}

// sameStem: a and b are the same Cyrillic word up to a case ending.
func sameStem(a, b []rune) bool {
	return isCyrillic(a) && isCyrillic(b) && stemRu(a) == stemRu(b)
}

// sameName: two spellings of one name. Latin names must be equal (a possessive 's aside): any shorter rule made Ann
// and Anton, Dan and Daphne, Bob and Boris one person. Cyrillic names are equal or differ by a case ending only
// (Даша, Даше, Дашу, Дашей); Оля and Олег, Маша and Даша are two. When unsure the names are two, and the open question
// stays open.
func sameName(a, b string) bool {
	ra, rb := foldWord(a), foldWord(b)
	return string(ra) == string(rb) || sameStem(ra, rb)
}

// enForms are a Latin word and the word with one simple English suffix taken off (-ing, -ed, -es, -s), when three
// letters are left.
func enForms(w []rune) []string {
	out := []string{string(w)}
	for _, suf := range []string{"ing", "ed", "es", "s"} {
		if len(w)-len(suf) >= 3 && strings.HasSuffix(string(w), suf) {
			out = append(out, string(w[:len(w)-len(suf)]))
		}
	}
	return out
}

// sameWord: two forms of one content word (launch/launches, move/moves, check/checking, рассылка/рассылку). Latin words
// are equal after one suffix, never by a shared beginning: mark and market, plan and planet are two.
func sameWord(a, b []rune) bool {
	if string(a) == string(b) || sameStem(a, b) {
		return true
	}
	if isCyrillic(a) || isCyrillic(b) {
		return false
	}
	for _, x := range enForms(a) {
		for _, y := range enForms(b) {
			if x == y {
				return true
			}
		}
	}
	return false
}

// settleStops are meeting words that carry no subject, added to the package's stopwords (echo_match.go) for the
// overlap below; ё is folded to е.
var settleStops = func() map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(`about when where why how into from need needs want wants let lets get got make made
		out off over under after before into what who
		нужно надо можно будет будем были было была быть есть давайте этот эта эти этом того этого том тем все всех
		после перед между через мне меня тебя себя свою свой когда где кто чем чего если`) {
		m[string(foldWord(w))] = true
	}
	return m
}()

// contentWords are the words of s that say what it is about: three letters or more, not a stopword.
func contentWords(s string) [][]rune {
	var out [][]rune
	for _, w := range tokens(s) {
		f := foldWord(w)
		if len(f) >= 3 && !stopwords[string(f)] && !settleStops[string(f)] {
			out = append(out, f)
		}
	}
	return out
}

// sharesContentWord: more than half of the open point's content words are in the decided one (at least one). A single
// generic word in common ("report") does not make a decision about an open question; the question's own subject must.
// A question with no content word is settled by nothing.
func sharesContentWord(open, decided string) bool {
	var classes [][]rune // the open point's words, one per sameWord class
	for _, w := range contentWords(open) {
		dup := false
		for _, c := range classes {
			dup = dup || sameWord(w, c)
		}
		if !dup {
			classes = append(classes, w)
		}
	}
	wd := contentWords(decided)
	used := make([]bool, len(wd)) // a decided word counts for one class only
	shared := 0
	for _, x := range classes {
		for i, y := range wd {
			if !used[i] && sameWord(x, y) {
				used[i] = true
				shared++
				break
			}
		}
	}
	return len(classes) > 0 && 2*shared > len(classes)
}

// settleOK is the code's check that a decided point can settle an open one: more than half of the open point's content words are in it,
// their numbers do not conflict (each states something the other lacks), and every name the open point mentions (not
// counting its first word) is mentioned by the decided one (sameName). An open point that names no one, or one that
// only gains a number or a name when it is settled, passes those two.
func settleOK(open, decided string) bool {
	if !sharesContentWord(open, decided) {
		return false
	}
	no, nd := numberSet(open), numberSet(decided)
	if !subsetKeys(no, nd) && !subsetKeys(nd, no) {
		return false
	}
	have := capitalized(decided, true)
	for _, n := range capitalized(open, false) {
		found := false
		for _, h := range have {
			found = found || sameName(n, h)
		}
		if !found {
			return false
		}
	}
	return true
}

// acceptSettles returns the open groups the claims settle. An open group (named by its rep) is settled when at least
// one decided point claimed for it belongs to a group that stays decided, comes from a part after the open group's
// last, and passes settleOK; the others are ignored. Which one passes does not matter to the notes, so the answer
// depends on the set of claims, not their order or the order of the ids in them. One decided point may settle several
// open groups. A settlement is a link from an open group to a decided one, never a union of groups, so nothing chains.
func acceptSettles(pts []pointRef, gs []pointGroup, claims []settleClaim) map[int]bool {
	groupOf := map[int]int{}
	for g, grp := range gs {
		for _, i := range grp.members {
			groupOf[i] = g
		}
	}
	byOpen := map[int][]int{}
	for _, c := range claims {
		byOpen[c.Open] = append(byOpen[c.Open], c.Decided...)
	}
	settled := map[int]bool{}
	for g, grp := range gs {
		if grp.status != statusOpen {
			continue
		}
		for _, d := range byOpen[grp.rep] {
			gd, ok := groupOf[d]
			if !ok || gs[gd].status != statusDecided || pts[d].Status != statusDecided ||
				pts[d].chunk <= grp.last || !settleOK(pts[grp.rep].Text, pts[d].Text) {
				continue
			}
			settled[g] = true
			break
		}
	}
	return settled
}

// mergePoints returns the decided and open lists of the meeting: each group once, under its status, in the words of
// its rep, in the order of the reps; an open group that a decided point settles is not listed.
func mergePoints(pts []pointRef, claims []settleClaim) (decided, open []string) {
	gs := buildGroups(pts)
	settled := acceptSettles(pts, gs, claims)
	order := make([]int, len(gs))
	for g := range order {
		order[g] = g
	}
	sort.Slice(order, func(a, b int) bool { return gs[order[a]].rep < gs[order[b]].rep })
	for _, g := range order {
		switch {
		case settled[g]:
		case gs[g].status == statusDecided:
			decided = append(decided, pts[gs[g].rep].Text)
		default:
			open = append(open, pts[gs[g].rep].Text)
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
		"properties": map[string]any{"settles": map[string]any{"type": "array", "items": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"open":    num,
				"decided": map[string]any{"type": "array", "items": num},
			},
			"required":             []string{"open", "decided"},
			"additionalProperties": false,
		}}},
		"required":             []string{"settles"},
		"additionalProperties": false,
	}
}

func pairSystem() string {
	return "You check the points of one meeting, written from different parts of its transcript. Each line is " +
		"\"[id] (part N, open|decided) text\". For each OPEN point, give the ids of the DECIDED points from a LATER part " +
		"that settle it: they answer the question it left open or make the decision it was waiting for, about the same " +
		"subject. Leave an open point out when nothing settles it. Never name a decided point about another person, " +
		"number or subject. Output only ids. " + untrustedRule
}

// reduceBatches lists the points for the reduce call(s): one line per group of the words-only merge, the open groups
// and the decided groups that come after the earliest of them. Up to maxReducePoints they go in one call. Over that,
// the open groups are split into at most maxReduceCalls slices and each slice goes with the decided groups that share
// the most words with it, filling the prompt to maxReducePoints; whatever does not fit keeps the words-only merge. So
// a meeting costs at most maxReduceCalls calls of at most maxReducePoints lines, and none when nothing is open or
// nothing was decided after it.
func reduceBatches(pts []pointRef) [][]int {
	var open, decided []pointGroup
	for _, g := range buildGroups(pts) {
		if g.status == statusOpen {
			open = append(open, g)
		} else {
			decided = append(decided, g)
		}
	}
	if len(open) == 0 || len(decided) == 0 {
		return nil
	}
	reps := func(gs []pointGroup, after int) []int {
		var out []int
		for _, g := range gs {
			if g.last > after {
				out = append(out, g.rep)
			}
		}
		return out
	}
	if len(open)+len(decided) <= maxReducePoints {
		first := open[0].last
		for _, g := range open {
			first = min(first, g.last)
		}
		later := reps(decided, first)
		if len(later) == 0 {
			return nil
		}
		return [][]int{sortedUnion(reps(open, -1), later)}
	}
	per := min((len(open)+maxReduceCalls-1)/maxReduceCalls, maxReducePoints/2)
	var out [][]int
	for lo := 0; lo < len(open) && len(out) < maxReduceCalls; lo += per {
		sl := open[lo:min(lo+per, len(open))]
		first := sl[0].last
		var slReps []int
		for _, g := range sl {
			first = min(first, g.last)
			slReps = append(slReps, g.rep)
		}
		near := reps(decided, first)
		score := map[int]float64{}
		for _, d := range near {
			for _, o := range slReps {
				score[d] = max(score[d], voices.WordOverlap(pts[d].Text, pts[o].Text))
			}
		}
		sort.SliceStable(near, func(a, b int) bool { return score[near[a]] > score[near[b]] })
		near = near[:min(len(near), maxReducePoints-len(slReps))]
		if len(near) > 0 {
			out = append(out, sortedUnion(slReps, near))
		}
	}
	return out
}

func sortedUnion(a, b []int) []int {
	out := append(append([]int(nil), a...), b...)
	sort.Ints(out)
	return out
}

// pairPoints asks the model which later decision settles each open point: at most maxReduceCalls calls (usually one),
// none when nothing can change (see reduceBatches). A failed batch is skipped; the first error is returned beside
// the claims of the other batches, for Compose to log. The claims are only claims: acceptSettles checks them, and
// without them the notes are the words-only merge.
func (c Composer) pairPoints(ctx context.Context, parts []ChunkNotes) ([]settleClaim, error) {
	pts := flattenPoints(parts)
	if len(pts) < 2 {
		return nil, nil
	}
	var claims []settleClaim
	var firstErr error
	for _, batch := range reduceBatches(pts) {
		got, err := c.pairBatch(ctx, pts, batch)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		claims = append(claims, got...)
	}
	return claims, firstErr
}

func (c Composer) pairBatch(ctx context.Context, pts []pointRef, batch []int) ([]settleClaim, error) {
	var b strings.Builder
	in := map[int]bool{}
	for _, i := range batch {
		in[i] = true
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
		Settles []settleClaim `json:"settles"`
	}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, err
	}
	var ok []settleClaim
	for _, cl := range out.Settles {
		if !in[cl.Open] { // an id the prompt did not list is not a claim about this prompt
			continue
		}
		kept := settleClaim{Open: cl.Open}
		for _, d := range cl.Decided {
			if in[d] {
				kept.Decided = append(kept.Decided, d)
			}
		}
		ok = append(ok, kept)
	}
	return ok, nil
}

func truncateRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
