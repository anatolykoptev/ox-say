package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// pad is a marker a fixture's transcript uses to force the next line into a new chunk: it is replaced by enough
// filler lines to fill one chunk (ChunkChars).
const pad = "{{PAD}}"

func expandPad(text string) string {
	filler := strings.Repeat("[9:99] Anatoly: "+strings.Repeat("filler ", 20)+"\n", ChunkChars/130+2)
	return strings.ReplaceAll(text, pad, filler)
}

func answerJSON(t *testing.T, a chunkAnswer) string {
	t.Helper()
	raw, err := json.Marshal(a)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// ownerFixture is a synthetic transcript, the model answers a good model would give for each of its chunks (in call
// order, the reduce call included when it is expected), and what the notes must hold. Synthetic only: nothing here
// is from a recording.
type ownerFixture struct {
	name       string
	lang       string
	transcript string
	replies    []string
	owners     map[string]string // task "what" -> expected owner ("" is "not stated")
	decided    []string
	open       []string
}

func ownerFixtures(t *testing.T) []ownerFixture {
	ans := func(a chunkAnswer) string { return answerJSON(t, a) }
	return []ownerFixture{
		{
			name:       "en: a request addressed by name and accepted",
			lang:       "en",
			transcript: "[0:05] Anatoly: Daphne, can you make a ticket for that?\n[0:09] Daphne: Sure, I will do it today.\n",
			replies: []string{ans(chunkAnswer{Summary: "A ticket was requested.", ActionItems: []modelAction{{
				What: "make a ticket", Owner: "Daphne", RequestedBy: "Anatoly", OwnerEvidence: evAddressedByName,
				Quote: "Daphne, can you make a ticket for that", When: "today"}}})},
			owners: map[string]string{"make a ticket": "Daphne"},
		},
		{
			name:       "en: a self-commitment",
			lang:       "en",
			transcript: "[0:02] Anatoly: I'll send the deck to the board tomorrow.\n",
			replies: []string{ans(chunkAnswer{Summary: "The deck goes out.", ActionItems: []modelAction{{
				What: "send the deck to the board", Owner: "Anatoly", OwnerEvidence: evSelfCommit,
				Quote: "I'll send the deck to the board tomorrow", When: "tomorrow"}}})},
			owners: map[string]string{"send the deck to the board": "Anatoly"},
		},
		{
			name:       "en: a request with no addressee",
			lang:       "en",
			transcript: "[0:10] Anatoly: Somebody needs to book the venue before Friday.\n[0:14] Daphne: Right, it is getting late.\n",
			replies: []string{ans(chunkAnswer{Summary: "The venue is not booked.", ActionItems: []modelAction{{
				What: "book the venue", OwnerEvidence: evUnstated, When: "before Friday"}}})},
			owners: map[string]string{"book the venue": ""},
		},
		{
			name:       "en: a vocative that is not a request",
			lang:       "en",
			transcript: "[0:30] Anatoly: Thanks, Daphne, that was a great walkthrough.\n[0:34] Daphne: Happy to help.\n",
			replies:    []string{ans(chunkAnswer{Summary: "The walkthrough went well."})},
			owners:     map[string]string{},
		},
		{
			name:       "ru: a request addressed by name and accepted",
			lang:       "ru",
			transcript: "[1:05] Анатолий: Мария, сделаешь тикет по этому вопросу?\n[1:09] Мария: Да, сделаю сегодня.\n",
			replies: []string{ans(chunkAnswer{Summary: "Нужен тикет.", ActionItems: []modelAction{{
				What: "сделать тикет", Owner: "Мария", RequestedBy: "Анатолий", OwnerEvidence: evAddressedByName,
				Quote: "Мария, сделаешь тикет по этому вопросу", When: "сегодня"}}})},
			owners: map[string]string{"сделать тикет": "Мария"},
		},
		{
			name:       "ru: a point discussed and left open",
			lang:       "ru",
			transcript: "[2:00] Мария: Делаем ли мы рассылку в этом месяце?\n[2:05] Анатолий: Пока не знаю, надо посмотреть бюджет.\n",
			replies: []string{ans(chunkAnswer{Summary: "Рассылка под вопросом.", Points: []Point{{
				Text: "Делать ли рассылку в этом месяце", Status: statusOpen, Quote: "Пока не знаю, надо посмотреть бюджет"}}})},
			open: []string{"Делать ли рассылку в этом месяце"},
		},
		{
			// open in the first chunk, agreed in the second, said in other words: the later chunk wins and the point
			// is listed once, as a decision. The reply order is: chunk 1, chunk 2, the reduce call, the summary merge.
			name:       "en: a point left open, agreed later in the meeting",
			lang:       "en",
			transcript: "[3:00] Daphne: Should we move the launch to March?\n[3:04] Anatoly: Not sure yet.\n" + pad + "[40:00] Daphne: So the launch is in March, agreed?\n[40:03] Anatoly: Yes, agreed, March it is.\n",
			replies: []string{
				ans(chunkAnswer{Summary: "Launch date discussed.", Points: []Point{{Text: "Should the launch move to March", Status: statusOpen}}}),
				ans(chunkAnswer{Summary: "Launch agreed.", Points: []Point{{Text: "The launch is in March", Status: statusDecided, Quote: "Yes, agreed, March it is"}}}),
				`{"same":[{"a":0,"b":1}]}`,
				"Launch date discussed and agreed.",
			},
			decided: []string{"The launch is in March"},
		},
	}
}

func composeWith(t *testing.T, f *fakeChat, text string, l Labels, lang string) Notes {
	t.Helper()
	n, err := Composer{Chat: f}.Compose(context.Background(), expandPad(text), l, lang)
	if err != nil {
		t.Fatalf("Compose: %v", err)
	}
	return n
}

func TestOwnerFixtures(t *testing.T) {
	for _, fx := range ownerFixtures(t) {
		t.Run(fx.name, func(t *testing.T) {
			n := composeWith(t, &fakeChat{replies: fx.replies}, fx.transcript, Labels{Me: "Anatoly", Them: "Other"}, fx.lang)
			got := map[string]string{}
			for _, a := range n.ActionItems {
				got[a.What] = a.Who
			}
			if fmt.Sprint(got) != fmt.Sprint(fx.owners) {
				t.Errorf("owners = %v, want %v", got, fx.owners)
			}
			if strings.Join(n.Decisions, "|") != strings.Join(fx.decided, "|") {
				t.Errorf("decisions = %q, want %q", n.Decisions, fx.decided)
			}
			if strings.Join(n.OpenQuestions, "|") != strings.Join(fx.open, "|") {
				t.Errorf("open questions = %q, want %q", n.OpenQuestions, fx.open)
			}
		})
	}
}

// quoteIn pins the quote rule: exact on words, forgiving on form only.
func TestQuoteMatchRule(t *testing.T) {
	text := "[0:05] Anatoly: Дафна, can you make a TICKET for that?\n[0:09] Артём: Ёжик, да."
	idx := newTextIndex(text)
	for _, c := range []struct {
		quote string
		want  bool
	}{
		{"Дафна, can you make a ticket for that", true},   // case and punctuation
		{"  can   you make\na ticket ", true},             // whitespace
		{"anatoly: дафна can you", true},                  // across the speaker label
		{"артем ежик", true},                              // ё/е
		{"Daphne, can you make a ticket for that", false}, // a different name
		{"can you make the ticket for that", false},       // one word changed
		{"can you make ticket", false},                    // one word dropped
		{"can you make a quick ticket for that", false},   // one word added
		{"ticket", false},                                 // one word is no evidence
		{"", false},
		{"[0:05] Anatoly дафна can you make", true},    // the timestamp is part of the text
		{"please make a ticket for that today", false}, // a paraphrase of real words
	} {
		if got := idx.has(c.quote); got != c.want {
			t.Errorf("has(%q) = %v, want %v", c.quote, got, c.want)
		}
	}
}

// F1: the request is addressed to Daphne and the model says so with the real words: the task is hers, with the
// evidence stored, and the asker is recorded as the asker.
func TestComposeGivesTheTaskToThePersonAsked(t *testing.T) {
	fx := ownerFixtures(t)[0]
	n := composeWith(t, &fakeChat{replies: fx.replies}, fx.transcript, Labels{Me: "Anatoly", Them: "Other"}, "en")
	if len(n.ActionItems) != 1 {
		t.Fatalf("items = %+v", n.ActionItems)
	}
	a := n.ActionItems[0]
	if a.Who != "Daphne" || a.RequestedBy != "Anatoly" || a.OwnerEvidence != evAddressedByName || a.Quote == "" {
		t.Fatalf("item = %+v, want Daphne asked by Anatoly with evidence and a quote", a)
	}
	md := NotesMarkdown(Manifest{}, n, "en")
	if !strings.Contains(md, "- [ ] Daphne — make a ticket — today") {
		t.Fatalf("notes.md:\n%s", md)
	}
}

// F2 (and the wrong-quote test of F1's mutation): a confident owner whose quote is not in the transcript is empty in
// notes.json and notes.md, and the task stays.
// Mutations: notes_points.go textIndex.has, return true for every quote -> RED here; notes_points.go
// modelAction.checked, delete the `a.Who = ""` under `case a.Quote == "":` -> RED here.
func TestComposeWrongQuoteClearsTheOwner(t *testing.T) {
	text := "[0:05] Anatoly: Somebody needs to make a ticket for that.\n"
	for name, m := range map[string]modelAction{
		"a quote that is not in the text":     {Owner: "Daphne", OwnerEvidence: evAddressedByName, Quote: "Daphne, can you make a ticket for that"},
		"a paraphrase of the text":            {Owner: "Daphne", OwnerEvidence: evAddressedByName, Quote: "somebody should make the ticket for that"},
		"an empty quote":                      {Owner: "Daphne", OwnerEvidence: evSelfCommit},
		"a one-word quote":                    {Owner: "Daphne", OwnerEvidence: evSelfCommit, Quote: "ticket"},
		"unstated evidence with a real quote": {Owner: "Daphne", OwnerEvidence: evUnstated, Quote: "Somebody needs to make a ticket"},
		"evidence outside the enum":           {Owner: "Daphne", OwnerEvidence: "obviously", Quote: "Somebody needs to make a ticket"},
	} {
		t.Run(name, func(t *testing.T) {
			m.What = "make a ticket"
			f := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", ActionItems: []modelAction{m}})}}
			n := composeWith(t, f, text, Labels{Me: "Anatoly", Them: "Other"}, "en")
			if len(n.ActionItems) != 1 || n.ActionItems[0].Who != "" || n.ActionItems[0].OwnerEvidence != evUnstated {
				t.Fatalf("items = %+v, want the task with no owner", n.ActionItems)
			}
			raw, _ := json.Marshal(n)
			if strings.Contains(string(raw), "Daphne") {
				t.Errorf("notes.json still names the owner: %s", raw)
			}
			if md := NotesMarkdown(Manifest{}, n, "en"); strings.Contains(md, "Daphne") || !strings.Contains(md, "- [ ] not stated — make a ticket — not stated") {
				t.Errorf("notes.md:\n%s", md)
			}
		})
	}
}

// The model gives the task to the asker while its evidence says the request was addressed to someone: the roles are
// swapped, so the owner is dropped rather than trusted.
// Mutation: notes_points.go modelAction.checked, delete the `case ev != evSelfCommit && ...` arm -> RED.
func TestComposeDropsAnOwnerWhoIsTheAsker(t *testing.T) {
	text := "[0:05] Anatoly: Daphne, can you make a ticket for that?\n"
	m := modelAction{What: "make a ticket", Owner: "Anatoly", RequestedBy: "Anatoly", OwnerEvidence: evAddressedByName,
		Quote: "Daphne, can you make a ticket for that"}
	n := composeWith(t, &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", ActionItems: []modelAction{m}})}}, text, Labels{Me: "Anatoly"}, "en")
	if n.ActionItems[0].Who != "" {
		t.Fatalf("item = %+v, want no owner", n.ActionItems[0])
	}
}

// F3: a point marked decided with no agreement quote (or one that is not in the text) is an open question only.
// Mutation: notes_points.go chunkAnswer.notes, change `claimed == statusDecided && p.Quote != ""` to
// `claimed == statusDecided` -> RED.
func TestComposeDecidedWithoutAnAgreementQuoteIsOpen(t *testing.T) {
	text := "[0:05] Daphne: Should we move the launch to March?\n[0:09] Anatoly: Let me think about it.\n"
	for name, quote := range map[string]string{"no quote": "", "a quote that is not there": "Yes, agreed, March it is"} {
		t.Run(name, func(t *testing.T) {
			f := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", Points: []Point{
				{Text: "Move the launch to March", Status: statusDecided, Quote: quote}}})}}
			n := composeWith(t, f, text, Labels{}, "en")
			if len(n.Decisions) != 0 || len(n.OpenQuestions) != 1 || n.OpenQuestions[0] != "Move the launch to March" {
				t.Fatalf("decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
			}
		})
	}
}

// F4: open in the first chunk and decided in the second (the reduce call pairs them): one point, a decision. And
// the other way round: decided, then reopened: one point, a question.
// Mutation: notes_points.go mergePoints, change `last = max(last, pts[i].chunk)` to `last = min(last, pts[i].chunk)`
// -> RED (the earlier chunk wins).
func TestComposeLaterChunkWins(t *testing.T) {
	fx := ownerFixtures(t)[6]
	n := composeWith(t, &fakeChat{replies: fx.replies}, fx.transcript, Labels{}, "en")
	if strings.Join(n.Decisions, "|") != "The launch is in March" || len(n.OpenQuestions) != 0 {
		t.Fatalf("decisions = %q, open = %q, want the decision only", n.Decisions, n.OpenQuestions)
	}
	text := "[3:00] Daphne: Launch is in March, agreed?\n[3:02] Anatoly: Yes, agreed, March it is.\n" + pad + "[40:00] Daphne: Wait, we cannot launch in March after all.\n"
	f := &fakeChat{replies: []string{
		answerJSON(t, chunkAnswer{Summary: "a", Points: []Point{{Text: "The launch is in March", Status: statusDecided, Quote: "Yes, agreed, March it is"}}}),
		answerJSON(t, chunkAnswer{Summary: "b", Points: []Point{{Text: "The launch is in March", Status: statusOpen}}}),
		"merged",
	}}
	n = composeWith(t, f, text, Labels{}, "en")
	if len(n.Decisions) != 0 || strings.Join(n.OpenQuestions, "|") != "The launch is in March" {
		t.Fatalf("decisions = %q, open = %q, want the question only", n.Decisions, n.OpenQuestions)
	}
	if len(f.reqs) != 3 {
		t.Fatalf("%d calls: identical points need no reduce call (2 chunks + the summary merge)", len(f.reqs))
	}
}

// oldNotesJSON is the shape notes.json had before the evidence fields: written by the code as it was, and its
// notes.md rendered by that code. Both must stay exactly as they are.
const oldNotesJSON = `{
 "summary": "Launch plan agreed.\n\nBudget still open.",
 "decisions": [
  "Ship the beta on Friday",
  "Use the final song version"
 ],
 "action_items": [
  {
   "who": "Daphne",
   "what": "make the ticket",
   "when": "today"
  },
  {
   "who": "",
   "what": "book the [venue](http://x)",
   "when": ""
  }
 ],
 "open_questions": [
  "Who pays for the ads?"
 ],
 "numbers": [
  "Budget: 5000 dollars"
 ],
 "skipped_chunks": [
  2
 ],
 "labels": {
  "voice:1": "Speaker 1",
  "voice:2": "Speaker 2"
 }
}`

const oldNotesMD = "# Sync — 0000-12-31 16:07\n\n## Summary\n\nLaunch plan agreed.\n\nBudget still open.\n\n## Decisions\n\n" +
	"- Ship the beta on Friday\n- Use the final song version\n\n## Action items\n\n- [ ] Daphne — make the ticket — today\n" +
	"- [ ] not stated — book the \\[venue\\](http://x) — not stated\n\n## Open questions\n\n- Who pays for the ads?\n\n" +
	"## Key numbers and dates\n\n- Budget: 5000 dollars\n\n_Part 3 of the transcript could not be summarized._\n"

// F5: a notes.json from before loads, renders to the same notes.md byte for byte, and writes back without a single
// new key (omitempty on the new fields; the json tags of the old ones unchanged).
// Mutations: notes.go ActionItem, remove `,omitempty` from the requested_by tag -> RED; rename the json tag
// "open_questions" -> RED.
func TestOldNotesJSONLoadsRendersAndWritesBackUnchanged(t *testing.T) {
	var n Notes
	if err := json.Unmarshal([]byte(oldNotesJSON), &n); err != nil {
		t.Fatal(err)
	}
	if got := NotesMarkdown(Manifest{Title: "Sync"}, n, "en"); got != oldNotesMD {
		t.Fatalf("notes.md changed:\n%s\nwant:\n%s", got, oldNotesMD)
	}
	out, err := json.MarshalIndent(n, "", " ")
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != oldNotesJSON {
		t.Fatalf("notes.json written back differs:\n%s", out)
	}
}

// F5, second half: the rename replay still works on a notes.json from before, and on one with the new fields.
func TestRenameReplaysOnOldAndNewNotesJSON(t *testing.T) {
	for name, tc := range map[string]struct{ json, want string }{
		"before": {oldNotesJSON, "- [ ] Daphne — make the ticket — today"},
		"after": {strings.Replace(oldNotesJSON, `"who": "Daphne"`, `"who": "Speaker 2", "requested_by": "Speaker 1", "owner_evidence": "addressed_by_name", "quote": "Speaker 2, can you make the ticket"`, 1),
			"- [ ] Maria — make the ticket — today"},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			id := f.start(t, 30, 30, 5000, false)
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			dir, _ := f.r.Store.Dir(id)
			var n Notes
			if err := json.Unmarshal([]byte(tc.json), &n); err != nil {
				t.Fatal(err)
			}
			n.Labels = map[string]string{SpeakerThem: "Speaker 2"}
			raw, _ := json.MarshalIndent(n, "", " ")
			if err := os.WriteFile(filepath.Join(dir, NotesJSON), raw, 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{SpeakerThem: "Maria"}}); err != nil {
				t.Fatal(err)
			}
			got := readFile(t, dir, NotesMD)
			if !strings.Contains(got, tc.want) {
				t.Fatalf("notes.md after the rename lacks %q:\n%s", tc.want, got)
			}
			var after Notes
			if err := json.Unmarshal([]byte(readFile(t, dir, NotesJSON)), &after); err != nil {
				t.Fatal(err)
			}
			if name == "after" && (after.ActionItems[0].RequestedBy != "Speaker 1" || after.ActionItems[0].Quote == "") {
				t.Errorf("the evidence did not survive the replay: %+v", after.ActionItems[0])
			}
		})
	}
}

// F6: the reduce call fails (or answers rubbish): the notes are written from the words-only merge and no error
// comes back. The call is made exactly once.
// Mutation: notes.go Compose, replace `c.pairPoints(ctx, parts)` with a call that returns the error (e.g. make
// pairPoints return (pairs, error) and `return Notes{}, err` on it) -> RED.
func TestComposeSurvivesAFailedReduceCall(t *testing.T) {
	fx := ownerFixtures(t)[6]
	for name, tc := range map[string]struct {
		reply string
		err   error
	}{
		"an error":         {"", errors.New("engine fell over")},
		"unreadable":       {"{not json", nil},
		"ids out of range": {`{"same":[{"a":-1,"b":99},{"a":0,"b":0}]}`, nil},
	} {
		t.Run(name, func(t *testing.T) {
			f := &fakeChat{replies: []string{fx.replies[0], fx.replies[1], tc.reply, "merged"}, errs: []error{nil, nil, tc.err}}
			n := composeWith(t, f, fx.transcript, Labels{}, "en")
			if len(f.reqs) != 4 {
				t.Fatalf("%d calls, want 2 chunks + 1 reduce + 1 summary", len(f.reqs))
			}
			// the paraphrase was not paired: both points stay, each under its own status
			if strings.Join(n.Decisions, "|") != "The launch is in March" || strings.Join(n.OpenQuestions, "|") != "Should the launch move to March" {
				t.Fatalf("decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
			}
			if n.Summary != "merged" {
				t.Fatalf("summary = %q: the summary merge must still run after a failed reduce", n.Summary)
			}
		})
	}
}

// The reduce call is bounded: none for a single chunk or when the code merge leaves fewer than two points, at most
// one otherwise; a pair inside one chunk, or between two different numbers, is ignored.
func TestReduceCallIsBoundedAndItsPairsAreChecked(t *testing.T) {
	one := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", Points: []Point{
		{Text: "Budget is 500", Status: statusOpen}, {Text: "Ads go live Monday", Status: statusOpen}}})}}
	composeWith(t, one, "[0:01] Anatoly: Budget is 500 and ads go live Monday.\n", Labels{}, "en")
	if len(one.reqs) != 1 {
		t.Fatalf("a single chunk made %d calls, want 1", len(one.reqs))
	}

	text := "[0:01] A: Budget talk.\n" + pad + "[50:00] B: Budget again.\n"
	chunk := func(pts ...Point) string { return answerJSON(t, chunkAnswer{Summary: "s", Points: pts}) }
	run := func(pair string, a, b Point) Notes {
		f := &fakeChat{replies: []string{chunk(a), chunk(b), pair, "merged"}}
		n := composeWith(t, f, text, Labels{}, "en")
		if len(f.reqs) != 4 {
			t.Fatalf("%d calls", len(f.reqs))
		}
		if req := f.reqs[2]; req.Schema == nil || !strings.Contains(req.User, "[0] (part 1, open)") || !strings.Contains(req.User, "[1] (part 2, decided)") {
			t.Fatalf("the reduce request is not the id list: %+v", req)
		}
		return n
	}
	q := "Agreed, budget talk again."
	// paraphrase: paired -> one decision
	n := run(`{"same":[{"a":0,"b":1}]}`, Point{Text: "What is the ad budget", Status: statusOpen}, Point{Text: "Ad spend is capped", Status: statusDecided, Quote: "Budget again"})
	_ = q
	if len(n.Decisions) != 1 || len(n.OpenQuestions) != 0 {
		t.Fatalf("paired: decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
	}
	// two different numbers are two points even when the model pairs them
	n = run(`{"same":[{"a":0,"b":1}]}`, Point{Text: "Budget 500 for ads", Status: statusOpen}, Point{Text: "Budget 700 for ads", Status: statusDecided, Quote: "Budget again"})
	if len(n.Decisions) != 1 || len(n.OpenQuestions) != 1 {
		t.Fatalf("different numbers: decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
	}
}

// Within one chunk a point listed both ways is one point and the doubt wins.
func TestSamePointInOneChunkWithBothStatusesIsOpen(t *testing.T) {
	text := "[0:01] Daphne: Ship on Friday? Yes, ship on Friday, fine.\n"
	f := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", Points: []Point{
		{Text: "Ship the beta on Friday", Status: statusDecided, Quote: "Yes, ship on Friday, fine"},
		{Text: "Ship the beta on Friday", Status: statusOpen}}})}}
	n := composeWith(t, f, text, Labels{}, "en")
	if len(n.Decisions) != 0 || len(n.OpenQuestions) != 1 {
		t.Fatalf("decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
	}
}

// D: a quote is stored cleaned, never rendered, and never a link: a transcript that holds markup gives a quote that
// cannot become one, and notes.md does not show it at all.
func TestQuoteIsStoredCleanedAndNeverRendered(t *testing.T) {
	text := "[0:05] Anatoly: Daphne, see [the doc](http://evil.example/x) and <img src=http://evil.example/p> please.\n"
	q := "Daphne, see [the doc](http://evil.example/x) and <img src=http://evil.example/p> please"
	f := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", ActionItems: []modelAction{{
		What: "read the doc", Owner: "Daphne", OwnerEvidence: evAddressedByName, Quote: q}}})}}
	n := composeWith(t, f, text, Labels{Me: "Anatoly"}, "en")
	got := n.ActionItems[0].Quote
	if got == "" || strings.Contains(strings.ReplaceAll(got, `\]`, ""), "](") || strings.Contains(strings.ReplaceAll(got, `\<`, ""), "<") {
		t.Fatalf("stored quote = %q: markup must be escaped", got)
	}
	if md := NotesMarkdown(Manifest{}, n, "en"); strings.Contains(md, "evil.example") {
		t.Fatalf("notes.md shows the quote:\n%s", md)
	}
}

// The schema is what llama-server turns into a grammar: one list of points with a two-value status, the four
// evidence values, and every field required, so a reply cannot omit the evidence.
func TestChunkSchemaShape(t *testing.T) {
	raw, _ := json.Marshal(chunkSchema())
	for _, want := range []string{`"points"`, `"enum":["decided","open"]`, `"enum":["self_commit","addressed_by_name","accepted_request","unstated"]`,
		`"required":["what","owner","requested_by","owner_evidence","quote","when"]`, `"required":["text","status","quote"]`} {
		if !strings.Contains(string(raw), want) {
			t.Errorf("schema lacks %s:\n%s", want, raw)
		}
	}
	for _, gone := range []string{`"decisions"`, `"open_questions"`} {
		if strings.Contains(string(raw), gone) {
			t.Errorf("schema still has %s", gone)
		}
	}
	sys := chunkSystem(Labels{Me: "A", Them: "B"}, "en")
	for _, want := range []string{"NEVER the one who asked", "unstated", "a wrong owner is worse than none"} {
		if !strings.Contains(sys, want) {
			t.Errorf("the prompt lacks %q", want)
		}
	}
	if strings.Contains(sys, "Attribute each action to the person who said they will do it") {
		t.Error("the old rule that reads a request as the requester's task is still in the prompt")
	}
}

// The measurement behind using the reduce call: by words alone only a restatement is one point; reworded points,
// the open-then-settled case among them, are missed (a miss costs a duplicate line, a false merge costs a
// decision), and facts that differ are never merged.
func TestWordsAloneMergeRestatementsAndMissParaphrases(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"Ship the beta on Friday", "Ship the beta on Friday.", true},
		{"Use the final song version", "We use the final song version", false},
		{"Should the launch move to March", "The launch is in March", false},
		{"Move the launch to March", "The launch is moved to March", false},
		{"Делать ли рассылку в этом месяце", "Рассылку в этом месяце делаем", false},
		{"Pay Bob 500 dollars for the shoot", "Pay Ann 500 dollars for the shoot", false},
	} {
		if got := samePoint(c.a, c.b); got != c.want {
			t.Errorf("samePoint(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}
