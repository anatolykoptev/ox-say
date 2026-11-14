package cli

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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

// Mutation: vocab.go cmdVocabSet, post to /approve for rm -> RED.
func TestVocabOkAndRm(t *testing.T) {
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Method+" "+r.URL.Path+" "+r.Header.Get("Content-Type"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"1a2b3c4d","heard":"Воксей","meant":"OxSay","status":"active"}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	var out, errb strings.Builder
	Run([]string{"vocab", "ok", "1a2b3c4d"}, &out, &errb, "test")
	Run([]string{"vocab", "rm", "1a2b3c4d"}, &out, &errb, "test")
	want := "POST /v1/glossary/1a2b3c4d/approve application/json,POST /v1/glossary/1a2b3c4d/reject application/json"
	if strings.Join(got, ",") != want {
		t.Fatalf("calls = %v", got)
	}
}
