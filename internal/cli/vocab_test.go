package cli

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/daemon"
)

// Mutation: vocab.go cmdVocabAdd, drop "context" from the request -> RED.
func TestVocabAddSendsThePair(t *testing.T) {
	body, code := captureBody(t, "vocab", "add", "Воксей", "OxSay", "--context", "сделай Воксей релиз")
	if code != 0 || body["heard"] != "Воксей" || body["meant"] != "OxSay" || body["context"] != "сделай Воксей релиз" {
		t.Fatalf("code %d body %v", code, body)
	}
	if _, ok := body["source"]; ok {
		t.Fatalf("add sent a source: %v", body)
	}
	if _, code := captureBody(t, "vocab", "add", "only-one"); code != 2 {
		t.Fatalf("one positional: code %d, want 2", code)
	}
	if _, code := captureBody(t, "vocab", "add", "a", "b", "--source", "owner"); code != 2 {
		t.Fatalf("--source accepted: code %d, want 2", code)
	}
}

// Mutation: vocab.go printPair, print p.Heard twice -> RED.
func TestVocabListPrintsPairs(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"pairs":[{"id":"1a2b3c4d","heard":"Воксей","meant":"OxSay","status":"candidate","seen":1}]}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	var out, errb strings.Builder
	if code := Run([]string{"vocab", "ls"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("code %d: %s", code, errb.String())
	}
	if want := "1a2b3c4d  candidate  Воксей → OxSay  (seen 1)\n"; out.String() != want {
		t.Fatalf("out = %q, want %q", out.String(), want)
	}
}

// ok/rm settle a pair and are the owner's word, so the command asks a person
// at a terminal — a piped call is refused before the daemon is even asked —
// and then posts with the bearer from $OX_SAY_HOME/owner.token. Only a bare
// "y" proceeds.
// Mutation: vocab.go cmdVocabSet, delete the vocabTTY refusal -> RED (a piped
// call approves the pair).
// Mutation: vocab.go cmdVocabSet, drop the Authorization header -> RED (the
// stub daemon sees no bearer).
// Mutation: vocab.go cmdVocabSet, treat every answer as yes -> RED ("n"
// approves).
func TestVocabOkAndRm(t *testing.T) {
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Method+" "+r.URL.Path+" "+r.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"pairs":[{"id":"1a2b3c4d","heard":"Воксей","meant":"OxSay","status":"candidate","seen":1}]}`))
			return
		}
		_, _ = w.Write([]byte(`{"id":"1a2b3c4d","heard":"Воксей","meant":"OxSay","status":"active"}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))

	home := t.TempDir()
	t.Setenv("OX_SAY_HOME", home)
	if err := os.WriteFile(filepath.Join(home, daemon.OwnerTokenFile), []byte("feed1234\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	oldTTY, oldIn := vocabTTY, vocabIn
	t.Cleanup(func() { vocabTTY, vocabIn = oldTTY, oldIn })
	run := func(in string, args ...string) (string, string, int) {
		vocabIn = strings.NewReader(in)
		var out, errb strings.Builder
		code := Run(args, &out, &errb, "test")
		return out.String(), errb.String(), code
	}

	// Not a terminal: refused before any HTTP call.
	vocabTTY = func(io.Reader, io.Writer) bool { return false }
	if _, errb, code := run("y\n", "vocab", "ok", "1a2b3c4d"); code != 2 || !strings.Contains(errb, "terminal") {
		t.Fatalf("piped: code %d err %q, want a terminal refusal", code, errb)
	}
	if len(got) != 0 {
		t.Fatalf("a piped call still hit the daemon: %v", got)
	}
	vocabTTY = func(io.Reader, io.Writer) bool { return true }

	// "y" approves: the pair is shown, the question asked, the bearer sent.
	out, _, code := run("y\n", "vocab", "ok", "1a2b3c4d")
	if code != 0 || !strings.Contains(out, "Воксей → OxSay") || !strings.Contains(out, "Approve? [y/N]") {
		t.Fatalf("ok: code %d out %q", code, out)
	}
	want := "GET /v1/glossary ,POST /v1/glossary/1a2b3c4d/approve Bearer feed1234"
	if strings.Join(got, ",") != want {
		t.Fatalf("calls = %v, want %v", got, want)
	}

	// Anything but a bare y — n, yes, enter — asks the daemon nothing.
	for _, in := range []string{"n\n", "yes\n", "\n"} {
		got = nil
		_, _, code = run(in, "vocab", "rm", "1a2b3c4d")
		if code != 1 || len(got) != 1 {
			t.Fatalf("answer %q: code %d calls %v; want 1 and only the list GET", in, code, got)
		}
	}

	// rm prompts Reject and posts to /reject.
	got = nil
	out, _, code = run("y\n", "vocab", "rm", "1a2b3c4d")
	if code != 0 || !strings.Contains(out, "Reject? [y/N]") {
		t.Fatalf("rm: code %d out %q", code, out)
	}
	if last := got[len(got)-1]; !strings.HasSuffix(last, "/reject Bearer feed1234") {
		t.Fatalf("rm calls = %v", got)
	}
}

// edit and purge are owner verbs too: no terminal means no daemon call at all,
// a bare "y" is the only yes, and the owner bearer goes with the request.
// Mutation: vocab.go vocabOwnerGate, delete the vocabTTY refusal -> RED
// (TestVocabPurgeNeedsATerminal: a piped purge reaches the daemon).
// Mutation: vocab.go vocabOwnerCall, drop the Authorization header -> RED.
func TestVocabEditAndPurge(t *testing.T) {
	var got []string
	var sent string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = append(got, r.Method+" "+r.URL.Path+" "+r.Header.Get("Authorization"))
		if r.Method != http.MethodGet {
			sent = string(b)
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"pairs":[{"id":"1a2b3c4d","heard":"Воксей","meant":"OxSay","status":"rejected","seen":1}]}`))
			return
		}
		_, _ = w.Write([]byte(`{"id":"1a2b3c4d","heard":"Воксей","meant":"OxPulse","status":"candidate","purged":"1a2b3c4d"}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	home := t.TempDir()
	t.Setenv("OX_SAY_HOME", home)
	if err := os.WriteFile(filepath.Join(home, daemon.OwnerTokenFile), []byte("feed1234\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldTTY, oldIn := vocabTTY, vocabIn
	t.Cleanup(func() { vocabTTY, vocabIn = oldTTY, oldIn })
	run := func(in string, args ...string) (string, string, int) {
		vocabIn = strings.NewReader(in)
		var out, errb strings.Builder
		code := Run(args, &out, &errb, "test")
		return out.String(), errb.String(), code
	}

	vocabTTY = func(io.Reader, io.Writer) bool { return false }
	for _, args := range [][]string{{"vocab", "edit", "1a2b3c4d", "OxPulse"}, {"vocab", "purge", "1a2b3c4d"}} {
		if _, errb, code := run("y\n", args...); code != 2 || !strings.Contains(errb, "terminal") {
			t.Fatalf("%v piped: code %d err %q, want a terminal refusal", args, code, errb)
		}
	}
	if len(got) != 0 {
		t.Fatalf("a piped call still hit the daemon: %v", got)
	}
	vocabTTY = func(io.Reader, io.Writer) bool { return true }

	for _, bad := range [][]string{{"vocab", "edit", "1a2b3c4d"}, {"vocab", "edit", "a", "b", "c"}, {"vocab", "purge"}, {"vocab", "purge", "a", "b"}} {
		if _, _, code := run("y\n", bad...); code != 2 {
			t.Fatalf("%v: code %d, want 2", bad, code)
		}
	}

	out, _, code := run("y\n", "vocab", "edit", "1a2b3c4d", "OxPulse")
	if code != 0 || !strings.Contains(out, "[y/N]") || !strings.Contains(out, "OxPulse") || sent != `{"meant":"OxPulse"}` {
		t.Fatalf("edit: code %d out %q sent %q", code, out, sent)
	}
	if want := "GET /v1/glossary ,POST /v1/glossary/1a2b3c4d/edit Bearer feed1234"; strings.Join(got, ",") != want {
		t.Fatalf("edit calls = %v, want %v", got, want)
	}

	got = nil
	for _, in := range []string{"n\n", "yes\n", "\n"} {
		if _, _, code = run(in, "vocab", "purge", "1a2b3c4d"); code != 1 {
			t.Fatalf("purge answer %q: code %d, want 1", in, code)
		}
	}
	if len(got) != 3 {
		t.Fatalf("declined purges asked the daemon more than the list: %v", got)
	}
	got = nil
	out, _, code = run("y\n", "vocab", "purge", "1a2b3c4d")
	if code != 0 || !strings.Contains(out, "deleted 1a2b3c4d") {
		t.Fatalf("purge: code %d out %q", code, out)
	}
	if want := "GET /v1/glossary ,DELETE /v1/glossary/1a2b3c4d Bearer feed1234"; strings.Join(got, ",") != want {
		t.Fatalf("purge calls = %v, want %v", got, want)
	}
}

// Mutation: vocab.go vocabOwnerGate, delete the vocabTTY refusal -> RED.
func TestVocabPurgeNeedsATerminal(t *testing.T) {
	hit := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
		_, _ = w.Write([]byte(`{"pairs":[]}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	oldTTY, oldIn := vocabTTY, vocabIn
	t.Cleanup(func() { vocabTTY, vocabIn = oldTTY, oldIn })
	vocabTTY = func(io.Reader, io.Writer) bool { return false }
	vocabIn = strings.NewReader("y\n")
	var out, errb strings.Builder
	if code := Run([]string{"vocab", "purge", "1a2b3c4d"}, &out, &errb, "test"); code != 2 || hit {
		t.Fatalf("code %d, daemon hit %v: purge ran without a terminal", code, hit)
	}
}

// A missing owner.token must not print the daemon home or the fs error.
// Mutation: vocab.go vocabOwnerGate, print filepath.Join(config.Home(), ...) and err again -> RED.
func TestVocabOwnerTokenFailureIsPathFree(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"pairs":[{"id":"1a2b3c4d","heard":"a","meant":"b","status":"candidate","seen":1}]}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	home := t.TempDir()
	t.Setenv("OX_SAY_HOME", home)
	oldTTY, oldIn := vocabTTY, vocabIn
	t.Cleanup(func() { vocabTTY, vocabIn = oldTTY, oldIn })
	vocabTTY = func(io.Reader, io.Writer) bool { return true }
	for _, args := range [][]string{{"vocab", "ok", "1a2b3c4d"}, {"vocab", "rm", "1a2b3c4d"}, {"vocab", "edit", "1a2b3c4d", "x"}, {"vocab", "purge", "1a2b3c4d"}} {
		vocabIn = strings.NewReader("y\n")
		var out, errb strings.Builder
		if code := Run(args, &out, &errb, "test"); code != 1 {
			t.Fatalf("%v: code %d, want 1", args, code)
		}
		if strings.Contains(errb.String(), home) || strings.Contains(errb.String(), "no such file") || !strings.Contains(errb.String(), "owner key") {
			t.Errorf("%v: stderr %q must name the owner key without a path or fs error", args, errb.String())
		}
	}
}
