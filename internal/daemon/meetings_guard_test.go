package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// servedFor is the handler `ox-say serve` runs for d: routes, then Guard, as
// ServerConfig wires them. Tests of what the app can do must go through it —
// the bare mux has no Content-Type check (the Swift client's bodiless POSTs
// were answered 415 in production while every mux-level test was green).
func servedFor(t *testing.T, d *Daemon) http.Handler {
	t.Helper()
	cfg := d.ServerConfig("test")
	h, err := mcpserver.Build(mcpserver.NewServer(&mcp.Implementation{Name: "ox-say", Version: "test"}, cfg), cfg)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// appRequest builds the request StudioClient.post (and the retention PUT)
// sends: a loopback Host, Content-Type: application/json, and `{}` when the
// action has no body of its own. No Origin, no Sec-Fetch-Site: URLSession sets
// neither.
func appRequest(method, path, body string) *http.Request {
	if body == "" && method != http.MethodDelete {
		body = "{}"
	}
	req := httptest.NewRequest(method, "http://127.0.0.1:8094"+path, strings.NewReader(body))
	if method != http.MethodDelete {
		req.Header.Set("Content-Type", "application/json")
	}
	return req
}

func serve(h http.Handler, req *http.Request) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// Every meeting call the app makes, with the exact headers and body the Swift
// client sends, passes the daemon's guard.
// Mutation: StudioClient.swift post() sends no body/Content-Type for nil body
// -> DictationCore testBodilessPostsStillCarryJSON RED (that is the app side
// of this contract). Mutation: internal/daemon/guard.go ServerConfig, delete
// `Middleware: ...Guard` -> TestGuardRefusesAMeetingPostWithoutJSON RED.
func TestMeetingCallsOfTheAppPassTheGuard(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\nexit 0\n")
	t.Cleanup(d.Shutdown)
	h := servedFor(t, d)

	rec := serve(h, appRequest("POST", "/v1/meetings", `{"title":"Plan","source":"zoom","labels":{"me":"A","them":"B"},"echo_risk":false}`))
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	writeTone(t, filepath.Join(created.Dir, meeting.MePCM), 30)

	if rec := serve(h, appRequest("POST", "/v1/meetings/"+created.ID+"/finish", "")); rec.Code != http.StatusAccepted {
		t.Fatalf("finish = %d %s", rec.Code, rec.Body)
	}
	if err := d.Meet.Process(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	if rec := serve(h, appRequest("POST", "/v1/meetings/"+created.ID+"/notes", "")); rec.Code != http.StatusAccepted {
		t.Fatalf("notes retry = %d %s", rec.Code, rec.Body)
	}
	if rec := serve(h, appRequest("POST", "/v1/meetings/notes-model/install", "")); rec.Code != http.StatusAccepted {
		t.Fatalf("model install = %d %s", rec.Code, rec.Body)
	}
	if rec := serve(h, appRequest("PUT", "/v1/meetings/settings", `{"retention_days":7}`)); rec.Code != http.StatusOK {
		t.Fatalf("retention = %d %s", rec.Code, rec.Body)
	}
	// The voiceover stop is bodiless too (the same StudioClient.post): an
	// unknown id is a 404 from the route, not a 415 from the guard (#252: assert the real outcome).
	// Mutation: internal/daemon/produce_ops.go:627, return nil in place of errNoProject for an invalid
	// id -> RED (200, not 404).
	if rec := serve(h, appRequest("POST", "/v1/produce/nope/cancel", "")); rec.Code != http.StatusNotFound {
		t.Fatalf("voiceover stop = %d %s, want 404 from the route", rec.Code, rec.Body)
	}
	for _, p := range []string{"/v1/meetings", "/v1/meetings/" + created.ID, "/v1/meetings/settings"} {
		if rec := serve(h, appRequest("GET", p, "")); rec.Code != http.StatusOK {
			t.Fatalf("GET %s = %d", p, rec.Code)
		}
	}
	// The meeting finished above was processed; deleting it needs no body.
	if err := d.Meet.Process(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	if rec := serve(h, appRequest("DELETE", "/v1/meetings/"+created.ID, "")); rec.Code != http.StatusNoContent {
		t.Fatalf("delete = %d %s", rec.Code, rec.Body)
	}
}

// The guard stays in the path: a meeting POST without a JSON Content-Type is
// 415, whatever its body. Proves the test above can fail.
// Mutation: internal/daemon/guard.go ServerConfig, delete the
// `Middleware: []mcpserver.Middleware{Guard},` line -> RED.
func TestGuardRefusesAMeetingPostWithoutJSON(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\nexit 0\n")
	t.Cleanup(d.Shutdown)
	h := servedFor(t, d)
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	for _, p := range []string{"/v1/meetings", "/v1/meetings/" + m.ID + "/finish", "/v1/meetings/" + m.ID + "/notes", "/v1/meetings/notes-model/install"} {
		for _, ct := range []string{"", "text/plain", "application/x-www-form-urlencoded"} {
			req := httptest.NewRequest("POST", "http://127.0.0.1:8094"+p, strings.NewReader("{}"))
			if ct != "" {
				req.Header.Set("Content-Type", ct)
			}
			if rec := serve(h, req); rec.Code != http.StatusUnsupportedMediaType {
				t.Errorf("POST %s with Content-Type %q = %d, want 415", p, ct, rec.Code)
			}
		}
		// A bodiless POST, the shape URLSession sends for body == nil.
		if rec := serve(h, httptest.NewRequest("POST", "http://127.0.0.1:8094"+p, nil)); rec.Code != http.StatusUnsupportedMediaType {
			t.Errorf("bodiless POST %s = %d, want 415", p, rec.Code)
		}
	}
}
