package daemon

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// statusBusy fetches /status and decodes the busy block — the wire view,
// so what is checked is what a client (the app's handshake) sees.
func statusBusy(t *testing.T, srv *httptest.Server) busySummary {
	t.Helper()
	resp, err := http.Get(srv.URL + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	var st struct {
		Busy busySummary `json:"busy"`
		Idle bool        `json:"idle"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		t.Fatal(err)
	}
	if st.Idle != st.Busy.idle() {
		t.Fatalf("idle=%v but busy=%+v", st.Idle, st.Busy)
	}
	return st.Busy
}

// A quiet daemon reports idle with every lane at zero — through the HTTP
// handler, so the wire shape itself is what is checked.
// Mutation: service.go Status, `Idle: busy.idle()` -> `Idle: true` -> RED
// everywhere below.
func TestStatusIdleWhenQuiet(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	srv := transcriptionServer(t, d)
	if b := statusBusy(t, srv); !b.idle() {
		t.Fatalf("quiet daemon busy = %+v, want all zero", b)
	}
}

// A speech request in flight counts under speaking (and interactive, which
// wraps the route): a kickstart during it would kill the render. The fake
// child blocks the request until its context ends, so the in-flight window
// is deterministic; the client cancel is what lets the handler return.
// Mutation: drop the speaking Add/defer pair in handleSpeech -> RED
// (busy.speaking stays 0 while the request is open).
func TestBusySpeaking(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_SPEECH_BLOCK", "1")
	d := newTestDaemon(t, dir, nil)
	srv := transcriptionServer(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel) // a failed assert must not leave the request blocking the cleanup
	done := make(chan error, 1)
	go func() {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			srv.URL+"/v1/audio/speech", strings.NewReader(`{"input":"hi"}`))
		if err != nil {
			done <- err
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			done <- err
			return
		}
		defer func() { _ = resp.Body.Close() }()
		_, err = io.Copy(io.Discard, resp.Body)
		done <- err
	}()
	testutil.WaitFor(t, 15*time.Second, func() bool {
		_, err := os.Stat(filepath.Join(dir, "speech-started"))
		return err == nil
	}, "the fake child's speech-started stamp")

	if b := statusBusy(t, srv); b.Speaking != 1 || b.Interactive != 1 || b.idle() {
		t.Fatalf("mid-speech busy = %+v, want speaking=1 interactive=1 idle=false", b)
	}
	cancel()
	<-done
	if b := statusBusy(t, srv); !b.idle() {
		t.Fatalf("busy = %+v after the request ended, want all zero", b)
	}
}

// The MCP speak tool shares the counter but not the HTTP route: it never
// passes the interactive wrapper, so only its own Add keeps a restart from
// killing the render.
// Mutation: drop the speaking Add/defer pair in Speak -> RED.
func TestBusySpeakingViaMCP(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_SPEECH_BLOCK", "1")
	d := newTestDaemon(t, dir, nil)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel) // a failed assert must not leave the request blocking the cleanup
	done := make(chan error, 1)
	go func() {
		_, err := d.Speak(ctx, SpeakInput{Text: "hi"})
		done <- err
	}()
	testutil.WaitFor(t, 15*time.Second, func() bool {
		_, err := os.Stat(filepath.Join(dir, "speech-started"))
		return err == nil
	}, "the fake child's speech-started stamp")
	if b := d.busy(); b.Speaking != 1 || b.Interactive != 0 || b.idle() {
		t.Fatalf("mid-speak busy = %+v, want speaking=1 interactive=0 idle=false", b)
	}
	cancel()
	<-done
	if b := d.busy(); !b.idle() {
		t.Fatalf("busy = %+v after the speak ended, want all zero", b)
	}
}

// A voice design in flight counts under designing for its whole run —
// slowDesign holds DesignVoice open at its top, so the check is not a race
// with the render.
// Mutation: drop the designing Add/defer pair in DesignVoice -> RED.
func TestBusyDesigning(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	hold := make(chan struct{})
	var release sync.Once
	releaseHold := func() { release.Do(func() { close(hold) }) }
	t.Cleanup(releaseHold) // a failed assert must not leave the design held
	d.slowDesign = func() { <-hold }
	done := make(chan error, 1)
	go func() {
		_, err := d.DesignVoice(context.Background(), DesignInput{
			Description: "a warm voice", Text: "hello there",
		})
		done <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.busy().Designing == 1
	}, "busy.designing while a design is held open")
	if b := d.busy(); b.idle() {
		t.Fatalf("idle with a design in flight: busy = %+v", b)
	}
	releaseHold()
	<-done // the design fails on this config (no vox engine) — irrelevant
	if b := d.busy(); b.Designing != 0 || !b.idle() {
		t.Fatalf("busy = %+v after the design returned, want designing=0", b)
	}
}

// An open streaming session counts under stt_sessions from the create's
// answer until finish or delete consumes it — a restart mid-session loses
// the dictation between chunks, which the in-flight request count cannot
// see.
// Mutation: drop the noteSTTSession call in handleSTTSessionCreate -> RED
// (stt_sessions stays 0 with a session open).
func TestBusySTTSessions(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)

	create := func() string {
		code, body := sessReq(t, http.MethodPost, base, "application/json", []byte("{}"))
		if code != http.StatusOK {
			t.Fatalf("create: status %d body %s", code, body)
		}
		var created struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(body, &created); err != nil || !sessionIDRe.MatchString(created.ID) {
			t.Fatalf("create body = %s, want {\"id\":<32 lowercase hex>}", body)
		}
		return created.ID
	}

	id := create()
	if b := statusBusy(t, srv); b.STTSessions != 1 || b.idle() {
		t.Fatalf("open session busy = %+v, want stt_sessions=1 idle=false", b)
	}
	code, _ := sessReq(t, http.MethodPost, base+"/"+id+"/finish", "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("finish: status %d", code)
	}
	if b := statusBusy(t, srv); b.STTSessions != 0 || !b.idle() {
		t.Fatalf("post-finish busy = %+v, want stt_sessions=0 idle=true", b)
	}

	// The delete leg, on a second session.
	id = create()
	code, _ = sessReq(t, http.MethodDelete, base+"/"+id, "", nil)
	if code != http.StatusOK {
		t.Fatalf("delete: status %d", code)
	}
	if b := statusBusy(t, srv); b.STTSessions != 0 {
		t.Fatalf("post-delete stt_sessions = %d, want 0", b.STTSessions)
	}
}

// An abandoned session cannot pin the daemon busy forever: its entry is
// reaped on the server's own idle window, the same TTL ox-stt applies.
// Mutation: drop the reap loop in sttSessions -> RED.
func TestBusySTTSessionReap(t *testing.T) {
	orig := sttSessionIdle
	sttSessionIdle = 50 * time.Millisecond
	t.Cleanup(func() { sttSessionIdle = orig })
	d := newTestDaemon(t, t.TempDir(), nil)

	d.noteSTTSession(strings.Repeat("a", 32))
	if b := d.busy(); b.STTSessions != 1 {
		t.Fatalf("stt_sessions = %d with a fresh entry, want 1", b.STTSessions)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.busy().STTSessions == 0
	}, "reap of an abandoned session")
}

// A running voiceover job counts under produce for its whole life — a
// restart loses it, and the app's own follower cannot be the signal: the
// job could belong to a CLI or MCP client.
// Mutation: producer.active -> return 0 unconditionally -> RED.
func TestBusyProduce(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	t.Setenv("OXSAY_FAKE_STT_JSON", `{"engine":"parakeet","language":"en","duration_s":1,"elapsed_s":0.1,"text":"hi","segments":[],"words":[]}`)
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	d.prod = newProducer(f)
	d.StartProducer()
	t.Cleanup(d.StopProducer)
	srv := transcriptionServer(t, d)

	if _, err := d.prod.create(reelInput(t)); err != nil {
		t.Fatal(err)
	}
	<-f.started // a slow render is in flight and stays so
	if b := statusBusy(t, srv); b.Produce != 1 || b.idle() {
		t.Fatalf("mid-render busy = %+v, want produce=1 idle=false", b)
	}
	close(f.block)
	testutil.WaitFor(t, 10*time.Second, func() bool {
		return d.busy().Produce == 0
	}, "busy.produce after the job ended")
}
