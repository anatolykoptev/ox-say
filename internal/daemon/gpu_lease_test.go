package daemon

import (
	"context"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// lastRunArgs returns the fake ox-stt's most recent argv record.
func lastRunArgs(t *testing.T, log string) []string {
	t.Helper()
	args := lastArgvArgs(t, log)
	if args == nil {
		t.Fatalf("no ox-stt argv recorded in %s", log)
	}
	return args
}

// lastRunPid returns the pid of the newest "start <id> <pid> <ns>" record,
// or 0 while the fake has not started a run.
func lastRunPid(t *testing.T, log string) int {
	t.Helper()
	pid := 0
	for _, l := range linesWith(sttLogLines(t, log), "start ") {
		f := strings.Fields(l)
		if len(f) >= 3 {
			pid, _ = strconv.Atoi(f[2])
		}
	}
	return pid
}

// pidfilePid reads the supervisor pidfile's pid field ("<pid> <token>").
func pidfilePid(t *testing.T, pidPath string) int {
	t.Helper()
	data, err := os.ReadFile(pidPath)
	if err != nil {
		t.Fatalf("pidfile %s: %v", pidPath, err)
	}
	pid, err := strconv.Atoi(strings.Fields(string(data))[0])
	if err != nil || pid <= 0 {
		t.Fatalf("pidfile %s unparsable: %q", pidPath, data)
	}
	return pid
}

func alive(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

// Issue #11, both directions end-to-end through the production wiring:
// a GPU ox-stt run (auto, lease free) holds the daemon's lease for its
// whole run; a speak arriving inside the window parks in EnsureReady's
// lease wait — it blocks, it does not fail — and spawns only once the
// transcription's lease frees.
// Mutation: drop the lease wait from EnsureReady's start branch -> RED
// (the engine spawns while the run is alive: Waiters never fills).
func TestSpeakBlocksWhileGPUTranscriptionRuns(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_STT_BLOCK", "1")
	d := newTestDaemon(t, dir, nil)
	log := sttSetup(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	sttCtx, stopSTT := context.WithCancel(context.Background())
	sttDone := make(chan error, 1)
	go func() {
		_, err := d.Transcribe(sttCtx, TranscribeInput{AudioPath: src})
		sttDone <- err
	}()
	var pid int
	testutil.WaitFor(t, 5*time.Second, func() bool {
		pid = lastRunPid(t, log)
		return pid != 0
	}, "GPU ox-stt run to start")
	t.Cleanup(func() {
		if pid > 0 {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	if args := lastRunArgs(t, log); argvHas(args, "-ng") {
		t.Fatalf("auto run on a free lease took -ng: argv %v", args)
	}
	if !d.gpu.Held() {
		t.Fatal("GPU ox-stt run is not holding the lease")
	}

	speakDone := make(chan error, 1)
	go func() {
		_, err := d.Speak(context.Background(), SpeakInput{Text: "hi"})
		speakDone <- err
	}()
	// Once a waiter is parked it cannot leave while the lease is held:
	// the wait's only exits are the token, the ctx (never expires here)
	// and the change broadcast — no transition happens while parked.
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.gpu.Waiters() == 1
	}, "speak's engine start to park on the held lease")
	if got := testutil.SpawnStamps(t, dir); got != 0 {
		t.Fatalf("engine spawned %d times while the GPU lease was held", got)
	}

	stopSTT() // the request dies; the fake child is killed and the lease freed
	if err := <-sttDone; err == nil {
		t.Fatal("cancelled GPU transcription returned nil")
	}

	// The freed token is handed straight to the parked waiter, so a free
	// gap is unobservable — the speak completing is the release's proof.
	select {
	case err := <-speakDone:
		if err != nil {
			t.Fatalf("speak after the lease freed: %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("speak never proceeded after the GPU lease freed")
	}
	if !d.gpu.Held() {
		t.Fatal("the spawned engine is not holding the lease")
	}
	if got := testutil.SpawnStamps(t, dir); got != 1 {
		t.Fatalf("spawn stamps = %d, want 1", got)
	}
	if d.Sup.State() != engine.StateReady {
		t.Fatalf("engine state = %s, want ready", d.Sup.State())
	}
}

// The idle-stop window end-to-end: the supervisor commits Stopped while the
// SIGTERM-ignoring child still lives, so "the engine holds the GPU" is the
// lease — a transcription landing inside the window must run with -ng.
// Once the child actually exits the lease frees and auto runs on GPU.
// Mutation: release the lease at the Stopped commit instead of at child
// exit -> RED (the in-window run goes without -ng).
func TestTranscribeDuringEngineTeardown(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_IGNORE_SIGTERM", "1")
	var pidPath string
	d := newTestDaemon(t, dir, func(ec *engine.Config) {
		ec.IdleStop = 300 * time.Millisecond
		ec.IdleTick = 20 * time.Millisecond
		ec.KillGrace = 30 * time.Second // the window stays open until the test kills
		pidPath = ec.PidPath
	})
	log := sttSetup(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	if _, err := d.Sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := pidfilePid(t, pidPath)
	// Runs before d.Shutdown (LIFO): frees the teardown wait whatever happens.
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })

	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.Sup.State() == engine.StateStopped
	}, "idle stop commit")
	if !alive(pid) {
		t.Fatal("the stopping engine child exited before its grace deadline")
	}
	if !d.gpu.Held() {
		t.Fatal("lease released at Stopped while the engine child still lives")
	}

	// The transcription inside the window must take the CPU.
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	if args := lastRunArgs(t, log); !argvHas(args, "-ng") {
		t.Fatalf("transcription during engine teardown ran WITHOUT -ng (argv %v)", args)
	}

	_ = syscall.Kill(pid, syscall.SIGKILL)
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return !d.gpu.Held()
	}, "lease release at the engine child's exit")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	if args := lastRunArgs(t, log); argvHas(args, "-ng") {
		t.Fatalf("transcription after the child exit still got -ng (argv %v)", args)
	}
}
