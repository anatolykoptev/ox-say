package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var searchT0 = time.Date(2026, 10, 20, 10, 0, 0, 0, time.UTC)

// seedMeeting is a finished meeting made of files: a title, the notes.md text, the transcript turns.
func seedMeeting(t *testing.T, d *Daemon, title, notes string, turns []meeting.Turn, started time.Time) meeting.Manifest {
	t.Helper()
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{
		Title: title, Started: started, Labels: meeting.Labels{Me: "Анатолий", Them: "Other"},
	}, started)
	if err != nil {
		t.Fatal(err)
	}
	if turns != nil {
		raw, _ := json.Marshal(turns)
		if err := os.WriteFile(filepath.Join(dir, meeting.TranscriptJSON), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if notes != "" {
		if err := os.WriteFile(filepath.Join(dir, meeting.NotesMD), []byte(notes), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := d.Meet.Store.Update(m.ID, func(mm *meeting.Manifest) { mm.Status = meeting.StatusDone })
	if err != nil {
		t.Fatal(err)
	}
	return *got
}

type searchHit struct {
	Field   string   `json:"field"`
	Snippet string   `json:"snippet"`
	Start   *float64 `json:"start"`
	Speaker string   `json:"speaker"`
}

type searchOut struct {
	Meetings []struct {
		ID    string      `json:"id"`
		Title string      `json:"title"`
		Hits  []searchHit `json:"hits"`
	} `json:"meetings"`
	Truncated bool `json:"truncated"`
}

func search(t *testing.T, mux http.Handler, q string) (searchOut, int, string) {
	t.Helper()
	rec := call(t, mux, "GET", "/v1/meetings/search?q="+url.QueryEscape(q), "")
	var out searchOut
	if rec.Code == http.StatusOK {
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("search body: %v: %s", err, rec.Body)
		}
	}
	return out, rec.Code, rec.Body.String()
}

func fields(o searchOut) []string {
	var f []string
	for _, m := range o.Meetings {
		for _, h := range m.Hits {
			f = append(f, h.Field)
		}
	}
	return f
}

// A Russian query matches whatever the case of the query or the text, and "ё" matches "е" both ways; the same for
// Latin letters with accents. "й" stays its own letter (it is not an "и" with a mark, to a Russian reader). The hits
// name the field; a transcript hit carries the time and the speaker's shown name.
// Mutation: internal/meeting/search.go foldRune, return r unchanged for non-ASCII (no case or diacritic fold) -> RED.
func TestSearchIgnoresCaseAndYoInRussian(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	seedMeeting(t, d, "Встреча по бюджету", "# Встреча по бюджету — 2026-10-20 10:00\n\n## Резюме\n\nОбсудили ёлочные игрушки.\n\n## Решения\n\n- Согласовать смету\n",
		[]meeting.Turn{
			{Speaker: meeting.SpeakerMe, S: 12.5, E: 20, Text: "Всем привет, начнём нашу ВСТРЕЧУ"},
			{Speaker: meeting.SpeakerThem, S: 65, E: 70, Text: "Ёжик пришёл, мой друг"},
		}, searchT0)

	cases := []struct {
		q     string
		field string
	}{
		{"ВСТРЕЧА", "title"},
		{"встреча по", "title"},
		{"елочные", "notes"},     // ё in the text, е in the query
		{"ЁЛОЧНЫЕ", "notes"},     // upper-case ё
		{"пришел", "transcript"}, // ё in the text
		{"ЕЖИК", "transcript"},
		{"смету", "notes"},
	}
	for _, c := range cases {
		out, code, body := search(t, mux, c.q)
		if code != http.StatusOK || len(out.Meetings) != 1 {
			t.Errorf("%q: %d %s", c.q, code, body)
			continue
		}
		found := false
		for _, h := range out.Meetings[0].Hits {
			found = found || h.Field == c.field
		}
		if !found {
			t.Errorf("%q: no %s hit in %s", c.q, c.field, body)
		}
	}
	// "й" is not "и": "мои" must not find "мой"
	if out, _, body := search(t, mux, "мои друг"); len(out.Meetings) != 0 {
		t.Errorf("й folded to и: %s", body)
	}
	if out, _, body := search(t, mux, "МОЙ друг"); len(out.Meetings) != 1 {
		t.Errorf("МОЙ друг: %s", body)
	}

	d2, mux2 := meetingFixture(t, nil)
	seedMeeting(t, d2, "Café société", "", nil, searchT0)
	for _, q := range []string{"cafe", "CAFÉ", "societe", "ÉTÉS"} {
		out, _, _ := search(t, mux2, q)
		want := q != "ÉTÉS"
		if (len(out.Meetings) == 1) != want {
			t.Errorf("latin %q: %d meetings", q, len(out.Meetings))
		}
	}
}

// The shape the app reads: {"meetings":[{id,title,started,status,hits:[{field,snippet,start?,speaker?}]}]}; start and
// speaker only on a transcript hit, and a start of 0 is still there.
func TestSearchResultShape(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m := seedMeeting(t, d, "Plan", "# Plan — x\n\nthe budget is approved\n", []meeting.Turn{
		{Speaker: meeting.SpeakerMe, S: 0, E: 4, Text: "budget first"},
	}, searchT0)
	rec := call(t, mux, "GET", "/v1/meetings/search?q=budget", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var raw struct {
		Meetings []map[string]any `json:"meetings"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	if len(raw.Meetings) != 1 || raw.Meetings[0]["id"] != m.ID || raw.Meetings[0]["title"] != "Plan" || raw.Meetings[0]["status"] != "done" || raw.Meetings[0]["started"] == nil {
		t.Fatalf("meeting = %v", raw.Meetings)
	}
	hits := raw.Meetings[0]["hits"].([]any)
	if len(hits) != 2 {
		t.Fatalf("hits = %v", hits)
	}
	notes, transcript := hits[0].(map[string]any), hits[1].(map[string]any)
	if notes["field"] != "notes" || notes["snippet"] == "" || notes["start"] != nil || notes["speaker"] != nil {
		t.Errorf("notes hit = %v", notes)
	}
	if transcript["field"] != "transcript" || transcript["start"] != float64(0) || transcript["speaker"] != "Анатолий" {
		t.Errorf("transcript hit = %v", transcript)
	}
}

// Newest first, at most 50 meetings, at most 5 hits each; truncated says there was more.
// Mutation: internal/meeting/search.go, MaxHitsPerMeeting 5 -> 50, or drop the meetings cap -> RED.
func TestSearchLimits(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	for i := range 60 {
		seedMeeting(t, d, fmt.Sprintf("Sync %d", i), "", nil, searchT0.Add(time.Duration(i)*time.Hour))
	}
	out, code, _ := search(t, mux, "sync")
	if code != http.StatusOK || len(out.Meetings) != 50 || !out.Truncated {
		t.Fatalf("code %d, %d meetings, truncated %v; want 50 and truncated", code, len(out.Meetings), out.Truncated)
	}
	if out.Meetings[0].Title != "Sync 59" || out.Meetings[49].Title != "Sync 10" {
		t.Errorf("order: %q ... %q", out.Meetings[0].Title, out.Meetings[49].Title)
	}
	if out, _, _ := search(t, mux, "sync 5"); out.Truncated {
		t.Error("truncated without more results")
	}

	d2, mux2 := meetingFixture(t, nil)
	var turns []meeting.Turn
	for i := range 12 {
		turns = append(turns, meeting.Turn{Speaker: meeting.SpeakerThem, S: float64(i * 10), E: float64(i*10 + 5), Text: fmt.Sprintf("the launch is on track, point %d", i)})
	}
	seedMeeting(t, d2, "Launch", "", turns, searchT0)
	out, _, _ = search(t, mux2, "launch")
	if len(out.Meetings) != 1 || len(out.Meetings[0].Hits) != 5 {
		t.Fatalf("hits = %v", fields(out))
	}
	if h := out.Meetings[0].Hits; h[0].Field != "title" || h[1].Field != "transcript" || *h[1].Start != 0 || *h[2].Start != 10 {
		t.Errorf("hit order: %+v", h)
	}
}

// A snippet is about 120 characters around the match, cut on character boundaries: Cyrillic is two bytes a letter,
// and a cut by bytes leaves half a letter.
// Mutation: internal/meeting/search.go snippet, slice the string by byte offsets instead of the rune slice -> RED.
func TestSearchSnippetIsCutOnRuneBoundaries(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	text := strings.Repeat("жук ", 60) + "ИСКОМОЕ слово" + strings.Repeat(" щит", 60)
	seedMeeting(t, d, "Long", "", []meeting.Turn{{Speaker: meeting.SpeakerMe, S: 3, E: 9, Text: text}}, searchT0)
	out, code, body := search(t, mux, "искомое")
	if code != http.StatusOK || len(out.Meetings) != 1 || len(out.Meetings[0].Hits) != 1 {
		t.Fatalf("%d %s", code, body)
	}
	s := out.Meetings[0].Hits[0].Snippet
	if !utf8.ValidString(s) || strings.ContainsRune(s, utf8.RuneError) {
		t.Fatalf("snippet is not valid UTF-8: %q", s)
	}
	if n := utf8.RuneCountInString(s); n < 100 || n > 124 {
		t.Errorf("snippet is %d characters, want about 120: %q", n, s)
	}
	if !strings.Contains(s, "ИСКОМОЕ слово") || !strings.HasPrefix(s, "…") || !strings.HasSuffix(s, "…") {
		t.Errorf("snippet = %q", s)
	}
	// a match at the very start has no leading ellipsis
	d2, mux2 := meetingFixture(t, nil)
	seedMeeting(t, d2, "Start", "", []meeting.Turn{{Speaker: meeting.SpeakerMe, S: 1, E: 2, Text: "Привет " + strings.Repeat("щ", 300)}}, searchT0)
	out, _, _ = search(t, mux2, "привет")
	if s := out.Meetings[0].Hits[0].Snippet; strings.HasPrefix(s, "…") || !strings.HasPrefix(s, "Привет") {
		t.Errorf("snippet at the start = %q", s)
	}
}

// Empty, blank and over-long queries are refused with a plain message; 200 characters (not bytes) are fine.
// Mutation: internal/meeting/search.go Search, drop the TrimSpace emptiness check or count bytes for the cap -> RED.
func TestSearchRefusesEmptyAndLongQueries(t *testing.T) {
	_, mux := meetingFixture(t, nil)
	for _, q := range []string{"", "   ", "\t\n"} {
		rec := call(t, mux, "GET", "/v1/meetings/search?q="+url.QueryEscape(q), "")
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "empty") {
			t.Errorf("q=%q: %d %s", q, rec.Code, rec.Body)
		}
	}
	if rec := call(t, mux, "GET", "/v1/meetings/search", ""); rec.Code != http.StatusBadRequest {
		t.Errorf("no q: %d", rec.Code)
	}
	long := strings.Repeat("я", 201)
	rec := call(t, mux, "GET", "/v1/meetings/search?q="+url.QueryEscape(long), "")
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "200") || strings.Contains(rec.Body.String(), "яяя") {
		t.Errorf("201 runes: %d %s", rec.Code, rec.Body)
	}
	if rec := call(t, mux, "GET", "/v1/meetings/search?q="+url.QueryEscape(strings.Repeat("я", 200)), ""); rec.Code != http.StatusOK {
		t.Errorf("200 runes (400 bytes): %d %s", rec.Code, rec.Body)
	}
}

// A meeting still being recorded or processed is searched by its title only: its files are being written or about to
// be replaced. The notes' own first line (the title again) and the section headings are not hits.
func TestSearchSkipsUnfinishedTextsAndHeadings(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	live := seedMeeting(t, d, "Roadmap", "# Roadmap — x\n\nsecretword here\n", []meeting.Turn{{Speaker: meeting.SpeakerMe, S: 1, E: 2, Text: "secretword"}}, searchT0)
	_, _ = d.Meet.Store.Update(live.ID, func(m *meeting.Manifest) { m.Status = meeting.StatusSummarizing })
	if out, _, body := search(t, mux, "secretword"); len(out.Meetings) != 0 {
		t.Errorf("unfinished meeting's texts searched: %s", body)
	}
	if out, _, _ := search(t, mux, "roadmap"); len(out.Meetings) != 1 || len(out.Meetings[0].Hits) != 1 || out.Meetings[0].Hits[0].Field != "title" {
		t.Errorf("unfinished meeting's title: %+v", out)
	}
	seedMeeting(t, d, "Alpha", "# Alpha — 2026\n\n## Решения\n\n- Ship it\n", nil, searchT0.Add(time.Hour))
	out, _, body := search(t, mux, "alpha")
	if len(out.Meetings) != 1 || len(out.Meetings[0].Hits) != 1 {
		t.Errorf("title echoed in the notes heading counts twice: %s", body)
	}
	if out, _, body := search(t, mux, "решения"); len(out.Meetings) != 0 {
		t.Errorf("section heading is a hit: %s", body)
	}
}

// The speaker of a hit is the name the user gave the voice, as the transcript shows it.
func TestSearchHitNamesTheSpeakerAsShown(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m := seedMeeting(t, d, "Call", "", []meeting.Turn{{Speaker: meeting.SpeakerThem, S: 5, E: 9, Text: "we will ship on friday"}}, searchT0)
	dir, _ := d.Meet.Store.Dir(m.ID)
	if err := meeting.SaveSpeakers(dir, meeting.SpeakerState{Version: meeting.SpeakersVersion, Names: map[string]string{"them": "Иван"}}); err != nil {
		t.Fatal(err)
	}
	out, _, body := search(t, mux, "friday")
	if len(out.Meetings) != 1 || out.Meetings[0].Hits[0].Speaker != "Иван" {
		t.Errorf("speaker: %s", body)
	}
}

// The MCP tool answers the same shape and refuses the same queries, and cannot change anything.
func TestSearchMCPToolMirrorsTheRoute(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	seedMeeting(t, d, "Бюджет", "", []meeting.Turn{{Speaker: meeting.SpeakerMe, S: 7, E: 9, Text: "утвердили бюджет"}}, searchT0)
	cs := mcpSession(t, d)
	got := callMCP(t, cs, "meetings_search", map[string]any{"query": "БЮДЖЕТ"})
	want, _, _ := search(t, mux, "БЮДЖЕТ")
	a, _ := json.Marshal(got)
	b, _ := json.Marshal(want)
	var ga, gb searchOut
	_ = json.Unmarshal(a, &ga)
	_ = json.Unmarshal(b, &gb)
	ha, _ := json.Marshal(ga.Meetings[0].Hits)
	hb, _ := json.Marshal(gb.Meetings[0].Hits)
	if len(ga.Meetings) != 1 || string(ha) != string(hb) {
		t.Errorf("tool %s\nroute %s", a, b)
	}
	res, err := cs.CallTool(t.Context(), &mcp.CallToolParams{Name: "meetings_search", Arguments: map[string]any{"query": "  "}})
	if err != nil || !res.IsError {
		t.Errorf("blank query: err %v, res %+v", err, res)
	}
	tools, _ := cs.ListTools(t.Context(), nil)
	for _, tool := range tools.Tools {
		if tool.Name == "meetings_search" && (tool.Annotations == nil || !tool.Annotations.ReadOnlyHint) {
			t.Errorf("meetings_search is not marked read-only: %+v", tool.Annotations)
		}
	}
}

// Nothing about the query or the meeting's words reaches a log, and a refusal does not echo the query back. The
// capture covers the daemon, the store and the runner.
// Mutation: internal/daemon/meetings_search.go handleMeetingSearch, add
// d.log.Info("search", slog.String("q", q)) (or log the query in the error path) -> RED.
func TestSearchLeaksNothingToLogsOrErrors(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	logs := logBuf(d)
	d.Meet.Log = d.log
	d.Meet.Store.Log = d.log
	m := seedMeeting(t, d, "Zebrafish plan", "# Zebrafish plan — x\n\nquokkasecret in the notes\n",
		[]meeting.Turn{{Speaker: meeting.SpeakerMe, S: 1, E: 2, Text: "the walrusmarker was said"}}, searchT0)
	dir, _ := d.Meet.Store.Dir(m.ID)
	// an unreadable text is skipped and counted, not logged with its content or path
	bad := seedMeeting(t, d, "Unreadable", "", nil, searchT0.Add(time.Hour))
	badDir, _ := d.Meet.Store.Dir(bad.ID)
	_ = os.Mkdir(filepath.Join(badDir, meeting.NotesMD), 0o700)

	for _, q := range []string{"quokkasecret", "walrusmarker", "ZEBRAFISH", "nomatchanywhere123", "  ", strings.Repeat("q", 300)} {
		body := call(t, mux, "GET", "/v1/meetings/search?q="+url.QueryEscape(q), "").Body.String()
		for _, bad := range []string{d.Cfg.Home, dir} {
			if strings.Contains(body, bad) {
				t.Errorf("response to %.12q names a path: %s", q, body)
			}
		}
		if (q == "  " || len(q) > 200) && (strings.Contains(body, "qqqq") || strings.Contains(body, "  ")) {
			t.Errorf("refusal echoes the query: %s", body)
		}
	}
	cs := mcpSession(t, d)
	_ = callMCP(t, cs, "meetings_search", map[string]any{"query": "quokkasecret"})
	_, _ = cs.CallTool(t.Context(), &mcp.CallToolParams{Name: "meetings_search", Arguments: map[string]any{"query": strings.Repeat("w", 300)}})

	log := logs.String()
	for _, secret := range []string{"quokkasecret", "walrusmarker", "zebrafish", "nomatchanywhere", "qqqqq", "wwwww", strings.ToLower(m.ID)} {
		if strings.Contains(strings.ToLower(log), secret) {
			t.Errorf("a log line carries %q:\n%s", secret, log)
		}
	}
	if strings.Contains(log, d.Cfg.Home) {
		t.Errorf("a log line names the home directory:\n%s", log)
	}
}

// The scan of 500 meetings, each the size of an hour's talk, is a plain read of their files; the time is logged
// (go test -v -run SearchTiming) and bounded loosely.
func TestSearchTimingOver500Meetings(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	words := strings.Fields("встреча бюджет квартал решение команда проект релиз клиент договор срок цена план отчёт задача вопрос ответ неделя пятница")
	for i := range 500 {
		var turns []meeting.Turn
		var notes strings.Builder
		notes.WriteString("# Планёрка — x\n\n## Резюме\n\n")
		for j := range 300 { // ~ an hour: 300 turns of ~30 words (~190 characters)
			var b strings.Builder
			for k := range 30 {
				b.WriteString(words[(i+j*7+k*3)%len(words)])
				b.WriteByte(' ')
			}
			turns = append(turns, meeting.Turn{Speaker: meeting.SpeakerThem, S: float64(j * 12), E: float64(j*12 + 10), Text: b.String()})
		}
		for j := range 40 {
			fmt.Fprintf(&notes, "- пункт %d: %s %s\n", j, words[j%len(words)], words[(j+i)%len(words)])
		}
		seedMeeting(t, d, fmt.Sprintf("Планёрка %d", i), notes.String(), turns, searchT0.Add(time.Duration(i)*time.Minute))
	}
	for _, q := range []string{"такого слова нет нигде", "ПЯТНИЦА"} {
		start := time.Now()
		out, code, _ := search(t, mux, q)
		el := time.Since(start)
		t.Logf("search %q over 500 meetings: %v (%d meetings in the answer, truncated %v)", q, el, len(out.Meetings), out.Truncated)
		if code != http.StatusOK || el > 30*time.Second {
			t.Errorf("%q: %d in %v", q, code, el)
		}
	}
}

// A request the client dropped stops the scan: the context is checked between meetings.
// Mutation: internal/daemon/meetings_search.go handleMeetingSearch, pass context.Background() instead of
// r.Context() -> RED (the cancelled request is still answered).
func TestSearchStopsWhenTheRequestIsCancelled(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	for i := range 5 {
		seedMeeting(t, d, fmt.Sprintf("Sync %d", i), "", nil, searchT0.Add(time.Duration(i)*time.Hour))
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest("GET", "/v1/meetings/search?q=sync", nil).WithContext(ctx)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Body.Len() != 0 {
		t.Fatalf("a cancelled search was answered: %d %s", rec.Code, rec.Body)
	}
	if _, err := d.Meet.Store.Search(ctx, "sync"); !errors.Is(err, context.Canceled) {
		t.Fatalf("Store.Search with a cancelled context: %v", err)
	}
	if n := d.searchGate.running.Load(); n != 0 {
		t.Fatalf("the search slot leaked: %d", n)
	}
}

// At most two searches scan at once; a third is told to come back (429, Retry-After) at once rather than held: the
// app searches as the user types and cancels the stale one, so waiting would only queue work nobody reads. The
// MCP tool shares the slots.
// Mutation: internal/daemon/meetings_search.go handleMeetingSearch, delete the tryAcquire branch -> RED.
func TestSearchIsCappedAtTwoAtOnce(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	seedMeeting(t, d, "Sync", "", nil, searchT0)
	if !d.searchGate.tryAcquire() || !d.searchGate.tryAcquire() {
		t.Fatal("the first two searches must get a slot")
	}
	rec := call(t, mux, "GET", "/v1/meetings/search?q=sync", "")
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("third search = %d %v %s", rec.Code, rec.Header(), rec.Body)
	}
	res, err := mcpSession(t, d).CallTool(t.Context(), &mcp.CallToolParams{Name: "meetings_search", Arguments: map[string]any{"query": "sync"}})
	if err != nil || !res.IsError {
		t.Fatalf("tool over the cap: err %v res %+v", err, res)
	}
	d.searchGate.release()
	if rec := call(t, mux, "GET", "/v1/meetings/search?q=sync", ""); rec.Code != http.StatusOK {
		t.Fatalf("after a release: %d %s", rec.Code, rec.Body)
	}
	if n := d.searchGate.running.Load(); n != 1 {
		t.Fatalf("slots held = %d, want 1 (the one still taken by the test)", n)
	}
}

// The size bound is enforced on the read itself: a transcript over it is skipped and counted, never read whole,
// whatever its size was when something last looked.
// Mutation: internal/meeting/search.go transcriptHits, call readTurnsMax(dir, 0) (no bound) -> RED.
func TestSearchSkipsATranscriptOverTheSizeBound(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	big := strings.Repeat("слово ", (9<<20)/len("слово ")) + " редкийтермин"
	seedMeeting(t, d, "Huge", "", []meeting.Turn{{Speaker: meeting.SpeakerMe, S: 1, E: 2, Text: big}}, searchT0)
	rec := call(t, mux, "GET", "/v1/meetings/search?q="+url.QueryEscape("редкийтермин"), "")
	var out struct {
		Meetings []any `json:"meetings"`
		Skipped  int   `json:"skipped"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	if rec.Code != http.StatusOK || len(out.Meetings) != 0 || out.Skipped != 1 {
		t.Fatalf("%d %.200s", rec.Code, rec.Body)
	}
}

// Only a Markdown heading (one to six # and a space) is left out of the notes search; "#42 fix" is text.
// Mutation: internal/meeting/search.go notesHits, skip every line that starts with "#" -> RED.
func TestSearchNotesSkipsHeadingsNotHashtags(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	seedMeeting(t, d, "Bugs", "# Bugs — x\n\n## Решения\n\n- #42 fix the login\n#7 also\n####### seven hashes\n", nil, searchT0)
	for q, want := range map[string]int{"42 fix": 1, "#7 also": 1, "seven hashes": 1, "решения": 0} {
		if out, _, body := search(t, mux, q); len(out.Meetings) != want {
			t.Errorf("%q: %d meetings, want %d: %s", q, len(out.Meetings), want, body)
		}
	}
}

// A letter typed as a base letter plus a combining mark (a decomposed é, and the й of a Russian keyboard layout
// that sends и + U+0306) finds its precomposed form and the other way round; й still does not become и (#268).
// Mutation: internal/meeting/search.go matchOnce, delete the `text = norm.NFC.String(text)` line -> RED (a
// decomposed text is not found by the precomposed query); the same in Search for `norm.NFC.String(q)` -> RED.
func TestSearchNormalisesDecomposedLetters(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	seedMeeting(t, d, "Café мой друг", "", nil, searchT0)
	d2, mux2 := meetingFixture(t, nil)
	seedMeeting(t, d2, "Café мой друг", "", nil, searchT0)
	d3, mux3 := meetingFixture(t, nil)
	seedMeeting(t, d3, "Plan", "# Plan\n\n## Summary\n\nThe cafe\u0301 is open\n", nil, searchT0)
	cases := []struct {
		name string
		mux  http.Handler
		q    string
		want bool
	}{
		{"precomposed query, decomposed notes", mux3, "caf\u00e9 is", true},
		{"decomposed query, precomposed title", mux, "café", true},
		{"decomposed й query, precomposed title", mux, "мой", true},
		{"precomposed query, decomposed title", mux2, "café", true},
		{"precomposed й query, decomposed title", mux2, "мой", true},
		{"и is not й, decomposed title", mux2, "мои друг", false},
		{"и is not й, precomposed title", mux, "мои друг", false},
	}
	for _, c := range cases {
		out, code, body := search(t, c.mux, c.q)
		if code != http.StatusOK || (len(out.Meetings) == 1) != c.want {
			t.Errorf("%s: want match=%v, got %d %s", c.name, c.want, code, body)
		}
	}
}
