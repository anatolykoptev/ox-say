package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/config"
)

// speechLog reads the bodies the fake engine saw (OXSAY_FAKE_SPEECH_LOG), in order.
func speechLog(t *testing.T, path string) []map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("speech log line %q: %v", line, err)
		}
		out = append(out, m)
	}
	return out
}

func boundsDaemon(t *testing.T, seed *int64) (*Daemon, string) {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	log := filepath.Join(dir, "speech.log")
	t.Setenv("OXSAY_FAKE_SPEECH_LOG", log)
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.Seed = seed }, nil, nil)
	return d, log
}

func routes(t *testing.T, d *Daemon) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func seedIn(m map[string]any) (int64, bool) {
	f, ok := m["seed"].(float64)
	return int64(f), ok
}

// #91 item 2: OX_SAY_SEED fills the seed of a request whose caller passed
// none, on every route to the engine; a per-request seed wins; with the
// variable unset no seed is invented.
// Mutation: drop the default-seed fill in prepareSpeech -> RED.
func TestDefaultSeed(t *testing.T) {
	ctx := context.Background()
	ptr := func(v int64) *int64 { return &v }

	d, log := boundsDaemon(t, ptr(4242))
	res, err := d.Speak(ctx, SpeakInput{Text: "hello there"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Seed == nil || *res.Seed != 4242 {
		t.Fatalf("Speak result seed = %v, want 4242", res.Seed)
	}
	if _, err := d.Speak(ctx, SpeakInput{Text: "hello there", Seed: ptr(7), Overwrite: true, OutPath: filepath.Join(t.TempDir(), "s.wav")}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.SynthesizeWAV(ctx, map[string]any{"input": "hello there"}); err != nil {
		t.Fatal(err)
	}
	srv := routes(t, d)
	body, _ := json.Marshal(map[string]any{"input": "hello there", "response_format": "wav"})
	resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()

	want := []int64{4242, 7, 4242, 4242}
	got := speechLog(t, log)
	if len(got) != len(want) {
		t.Fatalf("engine saw %d speech requests, want %d", len(got), len(want))
	}
	for i, w := range want {
		if s, ok := seedIn(got[i]); !ok || s != w {
			t.Errorf("request %d: engine seed = %v (present %v), want %d", i, s, ok, w)
		}
	}

	d2, log2 := boundsDaemon(t, nil)
	if _, err := d2.Speak(ctx, SpeakInput{Text: "hello there"}); err != nil {
		t.Fatal(err)
	}
	if got := speechLog(t, log2); len(got) != 1 {
		t.Fatalf("engine saw %d requests", len(got))
	} else if _, ok := seedIn(got[0]); ok {
		t.Fatalf("no OX_SAY_SEED: the daemon invented a seed: %v", got[0])
	}
}

// russian builds n chars of sentence-structured Russian text.
func russian(n int) string {
	const s = "Это одно короткое предложение для проверки разбиения длинного текста. "
	var b strings.Builder
	for utf8.RuneCountInString(b.String()) < n {
		b.WriteString(s)
	}
	return strings.TrimSpace(string([]rune(b.String())[:n]))
}

// #91 item 1: input longer than the engine speaks in one piece is split on
// sentence boundaries, every piece goes to the engine within the chunk size,
// the pieces rejoin to the caller's text, they share ONE seed (one voice), and
// the result is one take whose length covers every piece.
// Mutation: make Speak/synthesize send the whole text (drop splitSpeech) -> RED.
func TestLongInputIsSplitNotCut(t *testing.T) {
	d, log := boundsDaemon(t, nil)
	text := russian(4600) // under the 5000 cap, far over one engine call
	res, err := d.Speak(context.Background(), SpeakInput{Text: text, Language: "ru"})
	if err != nil {
		t.Fatal(err)
	}
	calls := speechLog(t, log)
	if len(calls) < 2 {
		t.Fatalf("a %d-char text reached the engine in %d call(s); it must be split", utf8.RuneCountInString(text), len(calls))
	}
	var rejoined []string
	var seed int64
	for i, c := range calls {
		in, _ := c["input"].(string)
		if n := utf8.RuneCountInString(in); n > qwenChunkChars || n == 0 {
			t.Errorf("piece %d is %d chars, limit %d", i, n, qwenChunkChars)
		}
		rejoined = append(rejoined, strings.Fields(in)...)
		s, ok := seedIn(c)
		if !ok {
			t.Fatalf("piece %d carries no seed: pieces would be spoken by different random voices", i)
		}
		if i == 0 {
			seed = s
		} else if s != seed {
			t.Errorf("piece %d seed %d != piece 0 seed %d", i, s, seed)
		}
	}
	if strings.Join(rejoined, " ") != strings.Join(strings.Fields(text), " ") {
		t.Errorf("pieces do not rejoin to the input")
	}
	if res.Seed == nil || *res.Seed != seed {
		t.Errorf("result seed %v, pieces used %d", res.Seed, seed)
	}
	// each fake take is 0.05 s: the file holds all of them plus the pauses
	if min := 0.05 * float64(len(calls)); res.DurationS < min {
		t.Errorf("take is %.2f s, the %d pieces alone are %.2f s", res.DurationS, len(calls), min)
	}
}

// A text that fits one call is not touched: one engine call, byte-identical.
func TestShortInputIsOneCall(t *testing.T) {
	d, log := boundsDaemon(t, nil)
	text := "Первое предложение. Второе предложение! Третье?"
	if _, err := d.Speak(context.Background(), SpeakInput{Text: text}); err != nil {
		t.Fatal(err)
	}
	calls := speechLog(t, log)
	if len(calls) != 1 || calls[0]["input"] != text {
		t.Fatalf("calls = %v", calls)
	}
}

// The HTTP route splits too (it used to stream a 5000-char text straight to
// the engine and relay the cut audio as complete).
func TestLongInputIsSplitOnHTTP(t *testing.T) {
	d, log := boundsDaemon(t, nil)
	srv := routes(t, d)
	for _, format := range []string{"wav", "pcm", ""} {
		body, _ := json.Marshal(map[string]any{"input": russian(4600), "response_format": format})
		resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("format %q: status %d", format, resp.StatusCode)
		}
	}
	if n := len(speechLog(t, log)); n < 6 {
		t.Fatalf("3 long requests produced %d engine calls; each must be split", n)
	}
}

func TestSplitSpeech(t *testing.T) {
	const max = 50
	check := func(name, text string, wantMin int) {
		t.Helper()
		parts := splitSpeech(text, max)
		if len(parts) < wantMin {
			t.Errorf("%s: %d parts, want >= %d: %q", name, len(parts), wantMin, parts)
		}
		for _, p := range parts {
			if p == "" || utf8.RuneCountInString(p) > max || !utf8.ValidString(p) {
				t.Errorf("%s: bad part %q", name, p)
			}
		}
		if strings.Join(strings.Fields(strings.Join(parts, " ")), "") != strings.Join(strings.Fields(text), "") {
			t.Errorf("%s: parts lose or reorder text: %q", name, parts)
		}
	}
	check("sentences", "Первое предложение здесь. Второе предложение там! Третье вопрос? Четвёртое снова. Пятое конец.", 2)
	check("one long sentence, commas", strings.Repeat("слово и ещё слово, ", 12), 3)
	check("one long sentence, no punctuation", strings.Repeat("слово ", 40), 3)
	check("no spaces at all", strings.Repeat("ж", 130), 3)
	check("newlines", "первая строка\n\nвторая строка\nтретья строка и ещё немного слов тут", 2)
	check("cjk full stops", strings.Repeat("今日は天気がいいです。", 12), 2)
	if got := splitSpeech("коротко.", max); len(got) != 1 || got[0] != "коротко." {
		t.Errorf("short text must come back as is: %q", got)
	}
	// sentences are packed, not one engine call each
	if got := splitSpeech("А. Б. В. Г. Д. Е.", max); len(got) != 1 {
		t.Errorf("short sentences must share a piece: %q", got)
	}
}

// #122: the engine's answer to a talker that never emitted EOS (its frame
// budget hit) is an ERROR everywhere — never a cut WAV that passes as a take —
// and the daemon counts it.
// Mutation: in speechOn, treat the runaway status as success (skip the
// non-200 branch) -> RED.
func TestRunawayIsAnError(t *testing.T) {
	t.Setenv("OXSAY_FAKE_SPEECH_RUNAWAY", "all")
	d, _ := boundsDaemon(t, nil)
	out := filepath.Join(t.TempDir(), "x.wav")
	_, err := d.Speak(context.Background(), SpeakInput{Text: "ox-say is ready", OutPath: out})
	if err == nil || !strings.Contains(err.Error(), "did not finish") {
		t.Fatalf("Speak error = %v", err)
	}
	if _, serr := os.Stat(out); serr == nil {
		t.Fatal("a file was written for a runaway take")
	}
	if got := d.Status().TTSFaults.Runaways; got != 2 { // the take and its one retry
		t.Fatalf("runaways counted = %d, want 2", got)
	}
	if !testLogSaw(t, "runaway") {
		t.Error("no runaway line in the daemon log")
	}
}

func TestRunawayOnHTTP(t *testing.T) {
	t.Setenv("OXSAY_FAKE_SPEECH_RUNAWAY", "all")
	d, _ := boundsDaemon(t, nil)
	srv := routes(t, d)
	body, _ := json.Marshal(map[string]any{"input": "ox-say is ready", "response_format": "wav"})
	resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway || !strings.Contains(string(raw), "did not finish") {
		t.Fatalf("status %d body %s", resp.StatusCode, raw)
	}
	if got := d.Status().TTSFaults.Runaways; got != 2 {
		t.Fatalf("runaways counted = %d, want 2", got)
	}
	var typed struct{ Error struct{ Type string } }
	if err := json.Unmarshal(raw, &typed); err != nil || typed.Error.Type != "generation_runaway" {
		t.Fatalf("error body has no typed code the app can read: %s", raw)
	}
}

// One piece of a split text running away fails the WHOLE request: the take
// is never delivered with a hole in it.
func TestRunawayInOnePieceFailsTheTake(t *testing.T) {
	t.Setenv("OXSAY_FAKE_SPEECH_RUNAWAY", "2+")
	d, _ := boundsDaemon(t, nil)
	out := filepath.Join(t.TempDir(), "x.wav")
	if _, err := d.Speak(context.Background(), SpeakInput{Text: russian(4600), OutPath: out}); err == nil {
		t.Fatal("a take with a runaway piece was delivered")
	}
	if _, serr := os.Stat(out); serr == nil {
		t.Fatal("a partial file was written")
	}
}

// A stream the engine cuts mid-body (its failure after the 200 went out) must
// reach the client as a broken transfer, not a clean end of a short audio.
// Mutation: ignore the copy error in handleSpeech's passthrough -> RED.
func TestCutStreamIsNotACleanEnd(t *testing.T) {
	t.Setenv("OXSAY_FAKE_SPEECH_ABORT", "1")
	d, _ := boundsDaemon(t, nil)
	srv := routes(t, d)
	body, _ := json.Marshal(map[string]any{"input": "ox-say is ready", "response_format": "pcm"})
	resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if _, err := io.ReadAll(resp.Body); err == nil {
		t.Fatal("client read a cut stream to a clean EOF")
	}
	if got := d.Status().TTSFaults.StreamAborts; got != 1 {
		t.Fatalf("stream aborts counted = %d, want 1", got)
	}
}

// The MCP speak tool reports a runaway as a tool error carrying the reason.
func TestRunawayOverMCP(t *testing.T) {
	t.Setenv("OXSAY_FAKE_SPEECH_RUNAWAY", "all")
	d, _ := boundsDaemon(t, nil)
	cs := mcpSession(t, d)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "speak", Arguments: map[string]any{"text": "ox-say is ready"}})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(res.Content)
	if !res.IsError || !strings.Contains(string(raw), "did not finish") {
		t.Fatalf("speak tool result: isError=%v content=%s", res.IsError, raw)
	}
}

func digitsRu() string { return strings.Repeat("25 ", 190) } // 570 chars typed, ~2600 spoken

// The split decision is made on the text the ENGINE gets: Russian numerals
// are written out (570 typed chars become ~2600 spoken), so measuring the
// typed text sends a short, digit-heavy input to the engine whole — #91 again.
// Mutation: http.go, measure `input` instead of `spoken` -> RED.
func TestDigitHeavyRussianIsSplitOnHTTP(t *testing.T) {
	for _, format := range []string{"pcm", "wav", ""} {
		d, log := boundsDaemon(t, nil)
		srv := routes(t, d)
		body, _ := json.Marshal(map[string]any{"input": digitsRu(), "response_format": format, "language": "ru"})
		resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		calls := speechLog(t, log)
		if len(calls) < 2 {
			t.Fatalf("format %q: %d engine call(s) for a text that speaks to ~2600 chars", format, len(calls))
		}
		for _, c := range calls {
			in, _ := c["input"].(string)
			if n := utf8.RuneCountInString(in); n > qwenChunkChars {
				t.Fatalf("format %q: engine got a %d-char piece, limit %d", format, n, qwenChunkChars)
			}
		}
	}
}

// The same operand on the Speak (CLI-free file route, MCP) path.
func TestDigitHeavyRussianIsSplitOnSpeak(t *testing.T) {
	d, log := boundsDaemon(t, nil)
	if _, err := d.Speak(context.Background(), SpeakInput{Text: digitsRu(), Language: "ru"}); err != nil {
		t.Fatal(err)
	}
	calls := speechLog(t, log)
	if len(calls) < 2 {
		t.Fatalf("%d engine call(s)", len(calls))
	}
	for _, c := range calls {
		in, _ := c["input"].(string)
		if n := utf8.RuneCountInString(in); n > qwenChunkChars {
			t.Fatalf("engine got a %d-char piece", n)
		}
	}
}

// A runaway on a seed the daemon filled in (OX_SAY_SEED) or on none is
// retried once on a fresh seed: the same seed would repeat it.
// Mutation: drop the retry loop in synthesizeQwenSplit / handleSpeech -> RED.
func TestRunawayRetriesOnAFreshSeed(t *testing.T) {
	ptr := func(v int64) *int64 { return &v }
	t.Setenv("OXSAY_FAKE_SPEECH_RUNAWAY", "1")
	d, log := boundsDaemon(t, ptr(42))
	res, err := d.Speak(context.Background(), SpeakInput{Text: "ox-say is ready"})
	if err != nil {
		t.Fatalf("a daemon-default seed runaway must be retried: %v", err)
	}
	calls := speechLog(t, log)
	if len(calls) != 2 {
		t.Fatalf("engine saw %d requests, want 2", len(calls))
	}
	s0, _ := seedIn(calls[0])
	s1, ok := seedIn(calls[1])
	if s0 != 42 || !ok || s1 == 42 {
		t.Fatalf("seeds %d then %d: the retry must use a fresh one", s0, s1)
	}
	if res.Seed == nil || *res.Seed != s1 {
		t.Fatalf("result seed %v, the take was made on %d", res.Seed, s1)
	}

	// the streaming-capable HTTP route retries too (qwen, short text)
	t.Setenv("OXSAY_FAKE_SPEECH_RUNAWAY", "1")
	d2, log2 := boundsDaemon(t, ptr(42))
	srv := routes(t, d2)
	body, _ := json.Marshal(map[string]any{"input": "ox-say is ready", "response_format": "wav"})
	resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	calls = speechLog(t, log2)
	if resp.StatusCode != http.StatusOK || len(calls) != 2 {
		t.Fatalf("HTTP: status %d after %d engine requests", resp.StatusCode, len(calls))
	}
	if a, _ := seedIn(calls[0]); a != 42 {
		t.Fatalf("first seed %d", a)
	}
	if b, _ := seedIn(calls[1]); b == 42 {
		t.Fatal("HTTP retry reused the seed")
	}
	if _, leaked := calls[0][fieldSeedDefaulted]; leaked {
		t.Fatal("the daemon's internal seed mark reached the engine")
	}
}

// A seed the request pinned is NOT swapped: the take fails, and the message
// does not promise that trying again helps.
func TestRunawayOnAPinnedSeedSaysSo(t *testing.T) {
	ptr := func(v int64) *int64 { return &v }
	t.Setenv("OXSAY_FAKE_SPEECH_RUNAWAY", "all")
	d, log := boundsDaemon(t, ptr(42))
	seven := int64(7)
	_, err := d.Speak(context.Background(), SpeakInput{Text: "ox-say is ready", Seed: &seven})
	if err == nil || !strings.Contains(err.Error(), "same seed") || strings.Contains(err.Error(), "try again") {
		t.Fatalf("error = %v", err)
	}
	if n := len(speechLog(t, log)); n != 1 {
		t.Fatalf("a pinned seed was retried: %d engine requests", n)
	}
	srv := routes(t, d)
	body, _ := json.Marshal(map[string]any{"input": "ox-say is ready", "response_format": "wav", "seed": 7})
	resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway || !strings.Contains(string(raw), "same seed") {
		t.Fatalf("HTTP: %d %s", resp.StatusCode, raw)
	}
	if n := len(speechLog(t, log)); n != 2 { // 1 from Speak + 1 here, no retry
		t.Fatalf("HTTP pinned seed retried: %d total engine requests", n)
	}
}

// seed -1 is the engine's "draw a random seed": it pins nothing. The split
// path must replace it (else the pieces are different voices) and the daemon
// default must replace it too.
// Mutation: seedFixed accepts negatives -> RED.
func TestNegativeSeedPinsNothing(t *testing.T) {
	ptr := func(v int64) *int64 { return &v }
	d, log := boundsDaemon(t, nil)
	if _, err := d.Speak(context.Background(), SpeakInput{Text: russian(1800), Language: "ru", Seed: ptr(-1)}); err != nil {
		t.Fatal(err)
	}
	calls := speechLog(t, log)
	if len(calls) < 2 {
		t.Fatalf("%d calls", len(calls))
	}
	first, _ := seedIn(calls[0])
	for i, c := range calls {
		if s, ok := seedIn(c); !ok || s < 0 || s != first {
			t.Fatalf("piece %d seed %d (present %v), piece 0 seed %d: pieces must share one non-negative seed", i, s, ok, first)
		}
	}

	d2, log2 := boundsDaemon(t, ptr(42))
	if _, err := d2.Speak(context.Background(), SpeakInput{Text: "ox-say is ready", Seed: ptr(-1)}); err != nil {
		t.Fatal(err)
	}
	if s, _ := seedIn(speechLog(t, log2)[0]); s != 42 {
		t.Fatalf("seed -1 with OX_SAY_SEED=42 reached the engine as %d", s)
	}
}
