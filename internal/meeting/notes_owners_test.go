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
	"time"
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
				`{"settles":[{"open":0,"decided":[1]}]}`,
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

// TestQuoteMatchRule pins the quote rule: exact on words inside one turn, forgiving on form only.
// Mutations: notes_points.go newTextIndex, replace `x.turns = append(x.turns, toks)` so all lines share turn 0 (no
// per-turn split) -> RED on the cross-turn and label cases; delete the norm.NFKC.String call in quoteTokens -> RED on
// the decomposed cases; delete the `len(q) > maxQuoteTokens` test in has -> RED on the oversized case.
func TestQuoteMatchRule(t *testing.T) {
	text := "[0:05] Anatoly: Дафна, can you make a TICKET for that?\n[0:09] Артём: Ёжик, да, I agree.\n" +
		"[0:12] Daphne: to ship on Friday.\n[0:20] Zo\u00eb: caf\u00e9 au lait\n[0:30] Ivan: \u0419\u043e\u0433\u0430 \u0438 \u0440\u044b\u0431\u0430\n"
	long := strings.Repeat("make ", maxQuoteTokens+1)
	idx := newTextIndex(text + "[0:40] Z: " + long + "\n") // the text really holds it: only the size rule can refuse
	for _, c := range []struct {
		name, quote string
		want        bool
	}{
		{"case and punctuation", "Дафна, can you make a ticket for that", true},
		{"whitespace", "  can   you make\na ticket ", true},
		{"e/yo", "ежик да", true},
		{"a different name", "Daphne, can you make a ticket for that", false},
		{"one word changed", "can you make the ticket for that", false},
		{"one word dropped", "can you make ticket", false},
		{"one word added", "can you make a quick ticket for that", false},
		{"one word is no evidence", "ticket", false},
		{"empty", "", false},
		{"a paraphrase of real words", "please make a ticket for that today", false},
		{"across the speaker label", "anatoly: дафна can you", false},
		{"the speaker label alone", "артем ёжик", false},
		{"the timestamp", "[0:05] Anatoly дафна can you make", false},
		{"across two turns", "I agree to ship on Friday", false},
		{"the end of a turn", "да I agree", true},
		{"composed against decomposed", "cafe\u0301 au lait", true},
		{"decomposed Y-breve against composed", "\u0438\u0306\u043e\u0433\u0430 \u0438", true},
		{"oversized", long, false},
	} {
		if got := idx.has(c.quote); got != c.want {
			t.Errorf("%s: has(%q) = %v, want %v", c.name, c.quote, got, c.want)
		}
	}
	if newTextIndex(strings.Repeat("[0:01] A: make make make\n", 5000)).has(strings.Repeat("make ", 59) + "x") {
		t.Error("a long non-match must be refused")
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

// oldNotesBody is notes.md after its first line, which holds the meeting time in the local time zone.
const oldNotesBody = "\n\n## Summary\n\nLaunch plan agreed.\n\nBudget still open.\n\n## Decisions\n\n" +
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
	started := time.Date(2026, 11, 10, 9, 30, 0, 0, time.UTC)
	got := NotesMarkdown(Manifest{Title: "Sync", Started: started}, n, "en")
	// The heading shows the time in the local zone (heading() in transcript.go): build it the same way, so the test
	// holds in any zone without touching time.Local.
	if want := "# Sync — " + started.Local().Format("2006-01-02 15:04"); !strings.HasPrefix(got, want) {
		t.Fatalf("heading = %q, want it to start with %q", strings.SplitN(got, "\n", 2)[0], want)
	}
	if body := got[strings.Index(got, "\n"):]; body != oldNotesBody {
		t.Fatalf("notes.md changed:\n%s\nwant:\n%s", body, oldNotesBody)
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
		"ids out of range": {`{"settles":[{"open":-1,"decided":[99]},{"open":0,"decided":[0,7]}]}`, nil},
	} {
		t.Run(name, func(t *testing.T) {
			f := &fakeChat{replies: []string{fx.replies[0], fx.replies[1], tc.reply, "merged"}, errs: []error{nil, nil, tc.err}}
			n := composeWith(t, f, fx.transcript, Labels{}, "en")
			if len(f.reqs) != 4 {
				t.Fatalf("%d calls, want 2 chunks + 1 reduce + 1 summary", len(f.reqs))
			}
			// nothing was settled: both points stay, each under its own status
			if strings.Join(n.Decisions, "|") != "The launch is in March" || strings.Join(n.OpenQuestions, "|") != "Should the launch move to March" {
				t.Fatalf("decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
			}
			if n.Summary != "merged" {
				t.Fatalf("summary = %q: the summary merge must still run after a failed reduce", n.Summary)
			}
		})
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

// Review 1: a quote lies inside one turn. Two turns joined, or a speaker label, do not show agreement or an owner.
// Mutation: notes_points.go newTextIndex, replace `x.turns = append(x.turns, toks)` with
// `x.turns = [][]string{append(append([]string(nil), firstOr(x.turns)...), toks...)}`-style joining (all lines one
// turn) -> RED here and in TestQuoteMatchRule.
func TestComposeQuoteAcrossTurnsOrLabelsIsRefused(t *testing.T) {
	text := "[0:05] Daphne: I agree\n[0:06] Anatoly: to ship Friday\n[0:09] Anatoly: Somebody make the ticket.\n"
	f := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s",
		Points: []Point{{Text: "Ship on Friday", Status: statusDecided, Quote: "I agree to ship Friday"}},
		ActionItems: []modelAction{{What: "make the ticket", Owner: "Anatoly", OwnerEvidence: evSelfCommit,
			Quote: "Anatoly: Somebody make the ticket"}},
	})}}
	n := composeWith(t, f, text, Labels{Me: "Anatoly"}, "en")
	if len(n.Decisions) != 0 || len(n.OpenQuestions) != 1 {
		t.Fatalf("decisions = %q, open = %q: a quote joining two turns is not agreement", n.Decisions, n.OpenQuestions)
	}
	if n.ActionItems[0].Who != "" {
		t.Fatalf("item = %+v: a quote that starts at a speaker label is not evidence", n.ActionItems[0])
	}
}

// The reduce call is bounded and its answer is only a claim: none for a single chunk, one otherwise; a claim about a
// decision of an earlier part, one that names another number, and an id out of range are ignored.
// Mutation: notes_points.go acceptSettles, delete `pts[d].chunk <= grp.last ||` -> RED on the earlier-part case.
func TestReduceCallIsBoundedAndItsClaimsAreChecked(t *testing.T) {
	one := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", Points: []Point{
		{Text: "Budget is 500", Status: statusOpen}, {Text: "Ads go live Monday", Status: statusOpen}}})}}
	composeWith(t, one, "[0:01] Anatoly: Budget is 500 and ads go live Monday.\n", Labels{}, "en")
	if len(one.reqs) != 1 {
		t.Fatalf("a single chunk made %d calls, want 1", len(one.reqs))
	}

	text := "[0:01] A: Budget talk.\n" + pad + "[50:00] B: Budget again.\n"
	chunk := func(pts ...Point) string { return answerJSON(t, chunkAnswer{Summary: "s", Points: pts}) }
	run := func(reply string, a, b Point) Notes {
		f := &fakeChat{replies: []string{chunk(a), chunk(b), reply, "merged"}}
		n := composeWith(t, f, text, Labels{}, "en")
		if len(f.reqs) != 4 {
			t.Fatalf("%d calls", len(f.reqs))
		}
		if req := f.reqs[2]; req.Schema == nil || !strings.Contains(req.User, "[0] (part 1, open)") || !strings.Contains(req.User, "[1] (part 2, decided)") {
			t.Fatalf("the reduce request is not the id list: %+v", req)
		}
		return n
	}
	open := Point{Text: "What is the ad budget", Status: statusOpen}
	dec := Point{Text: "The ad budget is capped", Status: statusDecided, Quote: "Budget again"}
	n := run(`{"settles":[{"open":0,"decided":[1]}]}`, open, dec)
	if len(n.Decisions) != 1 || len(n.OpenQuestions) != 0 {
		t.Fatalf("settled: decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
	}
	n = run(`{"settles":[{"open":0,"decided":[1]}]}`, Point{Text: "Budget 500 for ads", Status: statusOpen}, Point{Text: "Budget 700 for ads", Status: statusDecided, Quote: "Budget again"})
	if len(n.Decisions) != 1 || len(n.OpenQuestions) != 1 {
		t.Fatalf("different numbers: decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
	}
	// a decision of an earlier part settles nothing, and no call is made for it
	early := Point{Text: dec.Text, Status: statusDecided, Quote: "Budget talk"} // verifiable in the first part
	f := &fakeChat{replies: []string{chunk(early), chunk(open), "merged"}}
	n = composeWith(t, f, text, Labels{}, "en")
	if len(f.reqs) != 3 || len(n.Decisions) != 1 || len(n.OpenQuestions) != 1 {
		t.Fatalf("earlier part: %d calls, decisions = %q, open = %q", len(f.reqs), n.Decisions, n.OpenQuestions)
	}
	n = mergeChunks(partsOf(dec, open), Labels{}, []settleClaim{{Open: 1, Decided: []int{0}}})
	if len(n.Decisions) != 1 || len(n.OpenQuestions) != 1 {
		t.Fatalf("a claim about an earlier decision was accepted: decisions = %q, open = %q", n.Decisions, n.OpenQuestions)
	}
}

// Review (round 3): the check on a settlement. Names are compared by stem (case endings), numbers must not conflict,
// and a first word is not a name.
// Mutations (notes_points.go): sameName, replace `|| sameStem(ra, rb)` with a two-letter prefix test -> RED on the
// Ann/Anton and Dan/Daphne rows; stemRu, change `len(r)-l >= 3` to `>= 1` -> RED on the Олю/Оля row; sameStem, return
// false -> RED on the Даше/Даша rows; settleOK, delete the `if !sharesContentWord(open, decided)` block -> RED on the
// "new schedule" rows; capitalized, delete `&& strings.ToUpper(w) != w` -> RED on the API and NEW rows; delete the name
// loop -> RED on the name rows; in sharesContentWord change `2*shared > len(ow)` to `shared > 0` -> RED on the "report"
// rows and the generic-word row; in sharesContentWord delete the `dup = dup || sameWord(w, c)` line -> RED on the "Launch launches budget" row; in sameWord replace the enForms loop with a four-letter-prefix test -> RED in
// TestSameWord. Measured on these rows, the core pairs in English and Russian all pass with the
// threshold of more than half of the open point's content words (three letters or more, not a stopword, equal or with a case ending, at least one).
func TestSettleOK(t *testing.T) {
	for _, c := range []struct {
		open, decided string
		want          bool
	}{
		{"Нужно отправить Даше отчёт", "Отчёт отправит Даша", true}, // inflection: Даше / Даша
		{"Нужно отправить Даше отчёт", "Отчёт отправим Даше", true},
		{"Нужно отправить Даше отчёт", "Отчёт отправит Маша", false},
		{"Кто отправит отчёт Даше", "Даша получит отчёт", true},
		{"Pay Bob for the shoot", "Pay Ann for the shoot", false},
		{"Pay Bob for the shoot", "Bob is paid for the shoot", true},
		{"Open the office in Paris", "Open the office in Rome", false},
		{"Open the office in Paris", "Paris office it is", true},
		{"Budget 500 for ads", "Budget 700 for ads", false},
		{"What is the budget", "Budget is 700", true},
		{"Who does the ticket", "The ticket goes to Daphne", true},
		{"Should the launch move to March", "The launch is in March", true},
		{"Where do we meet", "We meet in Rome", true},
		// Latin names are equal or two people
		{"Should we ask Ann about the shoot", "Anton will ask about the shoot", false},
		{"Should we ask Dan about the shoot", "Daphne will ask about the shoot", false},
		{"Should we ask Bob about the shoot", "Boris will ask about the shoot", false},
		{"Should we ask Anna about the shoot", "Ann will ask about the shoot", false},
		{"Should we ask Bob about the shoot", "Bob's team will ask about the shoot", true},
		// Cyrillic: case endings only, and only on words of four letters or more
		{"Спросить ли Дашу про съёмку", "Даша спросит про съёмку", true},
		{"Спросить ли Дашу про съёмку", "Дашей съёмка согласована", true},
		{"Спросить ли Олю про съёмку", "Олег спросит про съёмку", false},
		{"Спросить ли Машу про съёмку", "Даша спросит про съёмку", false},
		{"Спросить ли Олю про съёмку", "Оля спросит про съёмку", false}, // too short to strip an ending: unsure, so two
		{"Спросить ли Марину про съёмку", "Мария спросит про съёмку", false},
		// the decision must be about the open point
		{"Should the launch move to March", "The office has a new schedule", false},
		{"Переносим ли запуск на март", "В офисе новое расписание", false},
		{"Переносим ли запуск на март", "Запуск в марте", true},
		// forms of one word are one word: "launch launches" is one of two subjects here, not two of three
		{"Launch launches budget", "Launches: the launch is on", false},
		{"Launch launches budget", "The launch and the budget", true},
		// verbs are not stemmed (выпускать / выпускаем): one of three content words is not enough, so this pair fails
		{"Должны ли мы выпускать рассылку", "Рассылку выпускаем по пятницам", false},
		{"Выпускать ли рассылку по пятницам", "Рассылка выходит по пятницам", true},
		// one generic word in common is not the subject
		{"Should the report go to finance", "The report is ready for review", false},
		{"Отправить ли отчёт в бухгалтерию", "Отчёт готов к проверке", false},
		// Петра is the genitive of Пётр: the same person, so this merge is right
		{"Спросить ли Петра про съёмку", "Пётр спросит про съёмку", true},
		// capitals: an acronym or an emphasis is a word, a name is a name
		{"Should we use the API for the report", "Use the interface for the report", true},
		{"Should we use the NEW report", "Use the report", true},
		{"Should we send the report to Bob", "Send the report to the client", false},
	} {
		if got := settleOK(c.open, c.decided); got != c.want {
			t.Errorf("settleOK(%q, %q) = %v, want %v", c.open, c.decided, got, c.want)
		}
	}
}

func partsOf(pts ...Point) []ChunkNotes {
	// one point per part, in order: part i is the i-th chunk
	var parts []ChunkNotes
	for _, p := range pts {
		parts = append(parts, ChunkNotes{Points: []Point{p}})
	}
	return parts
}

// A settlement is a map from an open point to a decision, never a graph. The model names several decisions for Bob's
// question, one about Ann; it is settled by the ones that pass the check, and the answer does not depend on the order
// of the claims or of the ids in them.
// Mutation: notes_points.go acceptSettles, replace `|| !settleOK(pts[grp.rep].Text, pts[d].Text) {` with `|| false {`
// -> RED on the "only Ann's decision" row.
func TestSettlementsAreChecksAndDoNotDependOnOrder(t *testing.T) {
	parts := partsOf(
		Point{Text: "Pay Bob for the shoot", Status: statusOpen},
		Point{Text: "Pay Ann for the shoot by card", Status: statusDecided},
		Point{Text: "Bob is paid for the shoot in cash", Status: statusDecided},
		Point{Text: "Bob is paid for the shoot by bank transfer", Status: statusDecided},
	)
	const settledBy2 = "Pay Ann for the shoot by card|Bob is paid for the shoot in cash|Bob is paid for the shoot by bank transfer // "
	for i, cl := range [][]settleClaim{
		{{Open: 0, Decided: []int{3, 2, 1}}},
		{{Open: 0, Decided: []int{1, 2, 3}}},
		{{Open: 0, Decided: []int{2}}, {Open: 0, Decided: []int{1}}},
		{{Open: 0, Decided: []int{3}}, {Open: 0, Decided: []int{1}}, {Open: 0, Decided: []int{2}}},
	} {
		n := mergeChunks(parts, Labels{}, cl)
		if got := strings.Join(n.Decisions, "|") + " // " + strings.Join(n.OpenQuestions, "|"); got != settledBy2 {
			t.Errorf("claims %d: %q, want %q", i, got, settledBy2)
		}
	}
	n := mergeChunks(parts, Labels{}, []settleClaim{{Open: 0, Decided: []int{1}}})
	if len(n.OpenQuestions) != 1 || len(n.Decisions) != 3 {
		t.Fatalf("decisions = %q, open = %q: only Ann's decision was named, Bob's question stays open", n.Decisions, n.OpenQuestions)
	}
	// One decision may settle several open points.
	two := partsOf(
		Point{Text: "Where do we meet", Status: statusOpen},
		Point{Text: "When do we meet", Status: statusOpen},
		Point{Text: "We meet at the office at noon", Status: statusDecided},
	)
	n = mergeChunks(two, Labels{}, []settleClaim{{Open: 0, Decided: []int{2}}, {Open: 1, Decided: []int{2}}})
	if len(n.Decisions) != 1 || len(n.OpenQuestions) != 0 {
		t.Fatalf("decisions = %q, open = %q: one decision settles both", n.Decisions, n.OpenQuestions)
	}
}

// Turns: a line without the "[m:ss] Name: " prefix continues the line before it, and so does a line with the same
// prefix (the pieces Chunk cuts an overlong line into). A different speaker starts a new turn.
// Mutation: notes_points.go newTextIndex, change `prefix == "" || prefix == lastPrefix` to `false` -> RED.
func TestContinuationLinesJoinThePreviousTurn(t *testing.T) {
	text := "[0:05] Daphne: I agree to ship\non Friday if QA is done.\n" +
		"[0:20] Anatoly: Let me think about the budget for\n[0:20] Anatoly: the ads next week.\n" +
		"[0:30] Daphne: Fine.\n"
	idx := newTextIndex(text)
	for _, c := range []struct {
		quote string
		want  bool
	}{
		{"agree to ship on Friday if QA is done", true},
		{"think about the budget for the ads next week", true},
		{"next week Fine", false}, // a new speaker is a new turn
		{"Daphne I agree", false},
	} {
		if got := idx.has(c.quote); got != c.want {
			t.Errorf("has(%q) = %v, want %v", c.quote, got, c.want)
		}
	}
	// through Chunk: an overlong line cut into pieces still holds a quote that runs over the cut
	long := "[0:01] Daphne: " + strings.Repeat("filler ", 40) + "I agree to ship on Friday\n"
	cut := strings.Join(Chunk(long, 150), "\n")
	if !newTextIndex(cut).has("I agree to ship on Friday") {
		t.Errorf("a quote over a Chunk cut is not found in:\n%s", cut)
	}
}

func distinctPoint(i int, status string, chunk int) pointRef {
	return pointRef{chunk: chunk, Point: Point{Text: fmt.Sprintf("topic%dalpha topic%dbeta topic%dgamma", i, i, i), Status: status}}
}

// Review 6: the reduce call is bounded by maxReduceCalls calls of at most maxReducePoints lines, and a long meeting
// does not lose the open-then-settled case: the open point goes with the decided ones most like it.
// Mutation: notes_points.go reduceBatches, replace the batching with `return nil` once
// len(open)+len(decided) > maxReducePoints -> RED (both tests).
func TestReduceBatchesAreBounded(t *testing.T) {
	var pts []pointRef
	for i := 0; i < 400; i++ {
		pts = append(pts, distinctPoint(i, statusOpen, 0))
	}
	for i := 400; i < 800; i++ {
		pts = append(pts, distinctPoint(i, statusDecided, 1))
	}
	batches := reduceBatches(pts)
	if len(batches) == 0 || len(batches) > maxReduceCalls {
		t.Fatalf("%d batches, want 1..%d", len(batches), maxReduceCalls)
	}
	for _, b := range batches {
		if len(b) > maxReducePoints {
			t.Fatalf("a batch of %d lines exceeds %d", len(b), maxReducePoints)
		}
	}
}

func TestLongMeetingStillPairsAnOpenPointWithItsDecision(t *testing.T) {
	const decided = 150
	text := "[0:01] A: Should we move the launch to March?\n" + pad + "[50:00] B: Agreed on everything here, done.\n"
	var pts []Point
	for i := 0; i < decided; i++ {
		pts = append(pts, Point{Text: fmt.Sprintf("topic%dalpha topic%dbeta topic%dgamma", i, i, i), Status: statusDecided, Quote: "Agreed on everything here"})
	}
	target := 97 // the decision that settles the open question, reworded
	pts[target].Text = "The launch moves to March"
	reduce := fmt.Sprintf(`{"settles":[{"open":0,"decided":[%d]}]}`, 1+target)
	f := &fakeChat{replies: []string{
		answerJSON(t, chunkAnswer{Summary: "a", Points: []Point{{Text: "Should the launch move to March", Status: statusOpen}}}),
		answerJSON(t, chunkAnswer{Summary: "b", Points: pts}),
		reduce, "merged",
	}}
	n := composeWith(t, f, text, Labels{}, "en")
	if len(f.reqs) != 4 {
		t.Fatalf("%d calls, want 2 chunks + 1 reduce + 1 summary", len(f.reqs))
	}
	if lines := strings.Count(f.reqs[2].User, "\n"); lines > maxReducePoints || !strings.Contains(f.reqs[2].User, "The launch moves to March") {
		t.Fatalf("the reduce prompt has %d lines and must hold the reworded decision:\n%.400s", lines, f.reqs[2].User)
	}
	if len(n.Decisions) != decided || len(n.OpenQuestions) != 0 {
		t.Fatalf("%d decisions, open = %q: the question and its decision are one point", len(n.Decisions), n.OpenQuestions)
	}
}

// Review 4: the schema asks for a bounded quote. Mutation: notes.go chunkSchema, delete `"maxLength": maxQuoteRunes`
// from quoteStr -> RED.
func TestChunkSchemaBoundsTheQuote(t *testing.T) {
	raw, _ := json.Marshal(chunkSchema())
	if got := strings.Count(string(raw), fmt.Sprintf(`"maxLength":%d`, maxQuoteRunes)); got != 2 {
		t.Fatalf("%d quote fields carry maxLength, want 2 (points, action items):\n%s", got, raw)
	}
}

// Latin content words match by one simple suffix, not by a shared beginning.
// Mutation: notes_points.go sameWord, replace the enForms loop with `return len(a) >= 4 && len(b) >= 4 && string(a[:4]) == string(b[:4])`
// -> RED (mark/market, plan/planet).
func TestSameWord(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"move", "moves", true}, {"launch", "launches", true}, {"check", "checking", true}, {"report", "reports", true},
		{"plan", "planet", false}, {"mark", "market", false}, {"ship", "shipment", false}, {"budget", "budgets", true},
		{"запуск", "запуске", true}, {"рассылка", "рассылку", true}, {"март", "марте", true}, {"отчёт", "отчет", true},
	} {
		if got := sameWord(foldWord(c.a), foldWord(c.b)); got != c.want {
			t.Errorf("sameWord(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

// A stored quote follows a rename, cleaned like the quote itself: a new name with markup in it stays escaped.
// Mutation: labels.go apply, delete the `a.Quote = replaceLabels(a.Quote, cleanFree)` line -> RED. (A label that is
// the single far-side one is exact-only, as in the notes text, so the replay test above leaves its quote alone.)
func TestRenameKeepsAStoredQuoteCleaned(t *testing.T) {
	c := labelChanges{free: map[string]string{"Speaker 2": "[Ivan](http://evil.example/x)"}, exact: map[string]string{}}
	n := c.apply(Notes{ChunkNotes: ChunkNotes{ActionItems: []ActionItem{{Who: "x", What: "y", Quote: "Speaker 2, can you make the ticket"}}}})
	q := n.ActionItems[0].Quote
	if !strings.HasPrefix(q, `\[Ivan\]`) || strings.Contains(strings.ReplaceAll(q, `\]`, ""), "](") {
		t.Fatalf("quote after the rename = %q: the new name must be escaped", q)
	}
}

// A cancelled run is not a finished one: when the reduce call is the one that is cut off, Compose returns the
// cancellation instead of notes that the runner would store as done.
// Mutation: notes.go Compose, delete the `if ctx.Err() != nil { return Notes{}, ctx.Err() }` under the pairPoints error
// -> RED.
func TestComposeCancelledInTheReduceCallReturnsTheCancellation(t *testing.T) {
	fx := ownerFixtures(t)[6]
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := &cancelOnCall{fakeChat: fakeChat{replies: []string{fx.replies[0], fx.replies[1]}}, at: 2, cancel: cancel}
	_, err := Composer{Chat: f}.Compose(ctx, expandPad(fx.transcript), Labels{}, "en")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
}

// cancelOnCall is a fakeChat whose call number `at` (from 0) cancels the run and fails.
type cancelOnCall struct {
	fakeChat
	at     int
	cancel context.CancelFunc
}

func (c *cancelOnCall) Complete(ctx context.Context, r Request) (string, error) {
	if len(c.reqs) == c.at {
		c.reqs = append(c.reqs, r)
		c.cancel()
		return "", ctx.Err()
	}
	return c.fakeChat.Complete(ctx, r)
}

// The quote must show the owner: a real quote about someone else does not make them the owner.
// Mutation: notes_points.go modelAction.checked, delete the `case a.Who != "" && !idx.showsOwner(m.Quote, ev, a.Who):`
// arm -> RED on the cleared rows; in showsOwner change `foldName(x.speakers[t]) == foldName(owner)` to `true` -> RED too.
func TestComposeOwnerMustBeShownByTheQuote(t *testing.T) {
	text := "[0:05] Anatoly: I'll send the deck to the board.\n[0:09] Anatoly: Somebody needs to book the venue.\n" +
		"[0:12] Daphne: Sure, I will do it today.\n[0:15] Anatoly: Daphne, can you make a ticket?\n"
	for name, tc := range map[string]struct {
		m    modelAction
		want string
	}{
		"self-commit quoted from another speaker": {modelAction{What: "send the deck", Owner: "Daphne", OwnerEvidence: evSelfCommit, Quote: "I'll send the deck to the board"}, ""},
		"self-commit quoted from the owner":       {modelAction{What: "send the deck", Owner: "Anatoly", OwnerEvidence: evSelfCommit, Quote: "I'll send the deck to the board"}, "Anatoly"},
		"addressed, the quote names no one":       {modelAction{What: "book the venue", Owner: "Daphne", OwnerEvidence: evAddressedByName, Quote: "Somebody needs to book the venue"}, ""},
		"addressed, the quote names the owner":    {modelAction{What: "make a ticket", Owner: "Daphne", OwnerEvidence: evAddressedByName, Quote: "Daphne, can you make a ticket"}, "Daphne"},
		"accepted, the quote is the owner's turn": {modelAction{What: "book the venue", Owner: "Daphne", OwnerEvidence: evAcceptedRequest, Quote: "Sure, I will do it today"}, "Daphne"},
		"accepted, the quote is another's turn":   {modelAction{What: "book the venue", Owner: "Daphne", OwnerEvidence: evAcceptedRequest, Quote: "Somebody needs to book the venue"}, ""},
	} {
		t.Run(name, func(t *testing.T) {
			f := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", ActionItems: []modelAction{tc.m}})}}
			n := composeWith(t, f, text, Labels{Me: "Anatoly"}, "en")
			if got := n.ActionItems[0].Who; got != tc.want {
				t.Fatalf("owner = %q, want %q (%+v)", got, tc.want, n.ActionItems[0])
			}
		})
	}
}

// Unnamed voices cannot refute an owner: the first real meeting had none named. Only a named person who is not the
// owner does.
// Mutation: notes_points.go showsOwner, delete the `if x.unnamed(sp) && evidence != evAddressedByName { return true }`
// block -> RED on the unnamed rows; in unnamed, return false -> RED too; delete the `|| sameName(sp, owner)` -> RED on
// the inflected-name row.
func TestUnnamedVoicesDoNotRefuteTheOwner(t *testing.T) {
	text := "[0:05] Speaker 2: I'll send the deck to the board.\n[0:09] Other: I'll book the venue.\n" +
		"[0:12] Anatoly: I'll make the ticket.\n[0:15] Me: I'll pay the invoice.\n[0:18] Даша: Я отправлю отчёт.\n" +
		"[0:20] Speaker 2: Somebody needs to call the client.\n"
	for name, tc := range map[string]struct {
		m    modelAction
		l    Labels
		want string
	}{
		"numbered voice, owner by name":        {modelAction{What: "send the deck", Owner: "Daphne", OwnerEvidence: evSelfCommit, Quote: "I'll send the deck to the board"}, Labels{Me: "Anatoly", Them: "Other"}, "Daphne"},
		"single far-side label, owner by name": {modelAction{What: "book the venue", Owner: "Daphne", OwnerEvidence: evSelfCommit, Quote: "I'll book the venue"}, Labels{Me: "Anatoly", Them: "Other"}, "Daphne"},
		"a named other person refutes":         {modelAction{What: "make the ticket", Owner: "Daphne", OwnerEvidence: evSelfCommit, Quote: "I'll make the ticket"}, Labels{Me: "Anatoly", Them: "Other"}, ""},
		"the recorder's label and its owner":   {modelAction{What: "pay the invoice", Owner: "Me", OwnerEvidence: evSelfCommit, Quote: "I'll pay the invoice"}, Labels{Me: "Me", Them: "Other"}, "Me"},
		"the recorder's label, another owner":  {modelAction{What: "pay the invoice", Owner: "Daphne", OwnerEvidence: evSelfCommit, Quote: "I'll pay the invoice"}, Labels{Me: "Me", Them: "Other"}, ""},
		"inflected name":                       {modelAction{What: "отправить отчёт", Owner: "Дашу", OwnerEvidence: evSelfCommit, Quote: "Я отправлю отчёт"}, Labels{Me: "Anatoly", Them: "Other"}, "Дашу"},
		"unnamed voice, addressed, no name":    {modelAction{What: "call the client", Owner: "Daphne", OwnerEvidence: evAddressedByName, Quote: "Somebody needs to call the client"}, Labels{Me: "Anatoly", Them: "Other"}, ""},
		"unnamed voice, accepted":              {modelAction{What: "call the client", Owner: "Daphne", OwnerEvidence: evAcceptedRequest, Quote: "Somebody needs to call the client"}, Labels{Me: "Anatoly", Them: "Other"}, "Daphne"},
	} {
		t.Run(name, func(t *testing.T) {
			f := &fakeChat{replies: []string{answerJSON(t, chunkAnswer{Summary: "s", ActionItems: []modelAction{tc.m}})}}
			n := composeWith(t, f, text, tc.l, "en")
			if got := n.ActionItems[0].Who; got != tc.want {
				t.Fatalf("owner = %q, want %q (%+v)", got, tc.want, n.ActionItems[0])
			}
		})
	}
}
