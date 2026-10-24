package cli

import (
	"context"
	"encoding/binary"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	mcpserver "github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/daemon"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type cannedNotes struct{}

func (cannedNotes) Complete(context.Context, meeting.Request) (string, error) {
	return `{"summary":"A call.","decisions":[],"action_items":[],"open_questions":[],"numbers":[]}`, nil
}

// finishMeeting records five seconds of audio and hands the meeting to the runner.
func finishMeeting(t *testing.T, d *daemon.Daemon) string {
	t.Helper()
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	pcm := make([]int16, 5*meeting.SampleRate)
	for i := range pcm {
		pcm[i] = 5000
	}
	raw := make([]byte, 2*len(pcm))
	for i, s := range pcm {
		binary.LittleEndian.PutUint16(raw[2*i:], uint16(s))
	}
	if err := os.WriteFile(filepath.Join(dir, meeting.MePCM), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Meet.Finish(m.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	return m.ID
}

// `ox-say serve` starts the meeting runner before serving and stops it after:
// a finished meeting is worked on while the daemon serves, and is left queued
// once serve has returned. The serve path is the production cmdServe with
// go-mcpserver's Serve replaced by a stub (no OnShutdown, so only cmdServe's
// own StopMeetings can stop the runner).
// Mutation: internal/cli/cli.go cmdServe - delete `d.StartMeetings()` -> RED
// (the meeting is never processed while serving).
// Mutation: internal/cli/cli.go cmdServe - delete `d.StopMeetings()` -> RED
// (the runner still processes a meeting after serve returned).
func TestServeStartsAndStopsTheMeetingRunner(t *testing.T) {
	home := t.TempDir()
	t.Setenv("OX_SAY_HOME", home)
	t.Setenv("OX_SAY_ADDR", "127.0.0.1:"+strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(testutil.FreePort(t)))

	oldNew, oldServe := newDaemon, serve
	defer func() { newDaemon, serve = oldNew, oldServe }()
	var d *daemon.Daemon
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) {
		var err error
		if d, err = daemon.New(cfg, l); err != nil {
			return nil, err
		}
		d.Meet.Transcribe = func(context.Context, string) (*stt.Result, error) {
			var w []stt.Word
			for i, tok := range strings.Fields("thanks everyone for joining today we will go through the plan and the open questions") {
				w = append(w, stt.Word{W: tok, S: 1 + float64(i)*0.4, E: 1.3 + float64(i)*0.4})
			}
			return &stt.Result{Words: w}, nil
		}
		d.Meet.Chat = cannedNotes{}
		d.Meet.NotesReady = func() string { return "" }
		return d, nil
	}
	state := func(id string) meeting.Status {
		m, err := d.Meet.Store.Load(id)
		if err != nil {
			t.Fatal(err)
		}
		return m.Status
	}
	var whileServing meeting.Status
	serve = func(_ *mcp.Implementation, _ mcpserver.Config, _ func(*mcp.Server)) error {
		id := finishMeeting(t, d)
		deadline := time.Now().Add(10 * time.Second)
		for state(id) != meeting.StatusDone && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		whileServing = state(id)
		return nil
	}
	var out, errb strings.Builder
	if code := Run([]string{"serve"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("serve exit %d: %s", code, errb.String())
	}
	if whileServing != meeting.StatusDone {
		t.Fatalf("a meeting finished while serving is %q: the runner was not started", whileServing)
	}
	after := finishMeeting(t, d)
	time.Sleep(400 * time.Millisecond)
	if got := state(after); got != meeting.StatusQueued {
		t.Fatalf("a meeting finished after serve returned is %q: the runner was not stopped", got)
	}
	d.Shutdown()
}

// `ox-say serve` finishes a recording whose app died mid-call: the runner's
// housekeeping sweeps orphans on its first round, ahead of the first tick.
// The serve path is the production cmdServe with go-mcpserver's Serve
// replaced by a stub that binds the configured address and polls the store.
// Mutation: internal/cli/cli.go cmdServe — delete `d.StartMeetings()` -> RED
// (the orphaned recording stays "recording" forever).
func TestServeFinishesAnOrphanedRecording(t *testing.T) {
	home := t.TempDir()
	t.Setenv("OX_SAY_HOME", home)
	t.Setenv("OX_SAY_ADDR", "127.0.0.1:"+strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_NOTES_PORT", strconv.Itoa(testutil.FreePort(t)))

	store := &meeting.Store{Root: filepath.Join(home, "meetings")}
	m, dir, err := store.Create(meeting.Manifest{Title: "orphan"}, time.Now().Add(-3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	pcm := make([]int16, 5*meeting.SampleRate)
	for i := range pcm {
		pcm[i] = 5000
	}
	raw := make([]byte, 2*len(pcm))
	for i, s := range pcm {
		binary.LittleEndian.PutUint16(raw[2*i:], uint16(s))
	}
	if err := os.WriteFile(filepath.Join(dir, meeting.MePCM), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * time.Hour)
	for _, name := range []string{meeting.MePCM, meeting.ManifestFile} {
		_ = os.Chtimes(filepath.Join(dir, name), old, old)
	}

	oldNew, oldServe := newDaemon, serve
	defer func() { newDaemon, serve = oldNew, oldServe }()
	var d *daemon.Daemon
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) {
		var err error
		if d, err = daemon.New(cfg, l); err != nil {
			return nil, err
		}
		d.Meet.Transcribe = func(context.Context, string) (*stt.Result, error) {
			var w []stt.Word
			for i, tok := range strings.Fields("thanks everyone for joining today we will go through the plan and the open questions") {
				w = append(w, stt.Word{W: tok, S: 1 + float64(i)*0.4, E: 1.3 + float64(i)*0.4})
			}
			return &stt.Result{Words: w}, nil
		}
		d.Meet.Chat = cannedNotes{}
		d.Meet.NotesReady = func() string { return "" }
		return d, nil
	}
	finished := false
	serve = func(_ *mcp.Implementation, cfg mcpserver.Config, _ func(*mcp.Server)) error {
		ln, err := net.Listen("tcp", net.JoinHostPort(cfg.Host, cfg.Port))
		if err != nil {
			return err
		}
		defer ln.Close()
		defer cfg.OnShutdown()
		for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
			if got, err := store.Load(m.ID); err == nil && got.Status == meeting.StatusDone {
				finished = true
				return nil
			}
		}
		return nil
	}
	var out, errb strings.Builder
	if code := Run([]string{"serve"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("serve exit %d: %s", code, errb.String())
	}
	if !finished {
		t.Fatal("serve never finished the orphaned recording")
	}
}
