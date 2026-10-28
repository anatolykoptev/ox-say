package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// --- the notes key can never leave the server open -------------------------

// withKeyWriter replaces the key writer for one test.
func withKeyWriter(t *testing.T, w func(*os.File, []byte) error) {
	t.Helper()
	old := notesKeyWrite
	notesKeyWrite = w
	t.Cleanup(func() { notesKeyWrite = old })
}

// A key write that fails leaves NO notes.key: llama-server stops on a missing
// key file, but starts open on an empty one. Here an old key is on disk and
// the new write dies half way (disk full).
// Mutation: internal/daemon/meetings.go writeNotesKey, delete the deferred
// `_ = os.Remove(path)` -> RED (the old key stays).
func TestAFailedKeyWriteLeavesNoKeyFile(t *testing.T) {
	cfg := testCfg(t, t.TempDir())
	key := filepath.Join(cfg.RunDir(), notesKeyFile)
	if err := os.MkdirAll(cfg.RunDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(key, []byte("old-key\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	withKeyWriter(t, func(f *os.File, b []byte) error {
		_, _ = f.Write(b[:5])
		return syscall.ENOSPC
	})
	if err := writeNotesKey(key); !errors.Is(err, syscall.ENOSPC) {
		t.Fatalf("err = %v, want the disk-full error", err)
	}
	for _, p := range []string{key, key + ".tmp"} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("%s survived a failed key write (%v)", filepath.Base(p), err)
		}
	}
}

// startNotesFake builds a daemon whose ox-llm is the fake child, with its
// spawn stamps in the returned dir.
func startNotesFake(t *testing.T) (*Daemon, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
	d, _ := meetingFixture(t, func(c *config.Config) {
		model := filepath.Join(dir, "models", config.NotesModelFile)
		_ = os.MkdirAll(filepath.Dir(model), 0o755)
		_ = os.WriteFile(model, []byte("x"), 0o600)
		c.NotesBin, c.NotesPort, c.NotesModel = os.Args[0], testutil.FreePort(t), model
	})
	return d, dir
}

func spawnStamps(t *testing.T, dir string) []string {
	t.Helper()
	marks, err := filepath.Glob(filepath.Join(dir, "llm-spawn-*"))
	if err != nil {
		t.Fatal(err)
	}
	return marks
}

func waitProcessGone(t *testing.T, pid int, what string) {
	t.Helper()
	testutil.WaitFor(t, 5*time.Second, func() bool { return syscall.Kill(pid, 0) == syscall.ESRCH }, what+" to exit")
}

// A key file that holds no key — whatever way it came to be empty — stops the
// start before the child is spawned.
// Mutation: internal/daemon/meetings.go checkNotesKey, delete the
// `len(bytes.TrimSpace(raw)) == 0` branch -> RED (the child is spawned).
func TestAnEmptyKeyFileRefusesTheStart(t *testing.T) {
	d, dir := startNotesFake(t)
	withKeyWriter(t, func(*os.File, []byte) error { return nil }) // "succeeds", writes nothing
	_, err := d.LLMSup.EnsureReady(context.Background())
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("err = %v, want a refusal naming the empty key", err)
	}
	if m := spawnStamps(t, dir); len(m) != 0 {
		t.Fatalf("ox-llm was spawned with an empty key file: %v", m)
	}
	if _, err := os.Lstat(filepath.Join(d.Cfg.RunDir(), notesKeyFile)); !os.IsNotExist(err) {
		t.Fatalf("the bad key file was left behind (%v)", err)
	}
}

// Mutation: internal/daemon/meetings.go checkNotesKey, delete the
// `st.Mode().Perm() != 0o600` branch -> RED (a world-readable key is used).
func TestAKeyFileThatIsNotPrivateRefusesTheStart(t *testing.T) {
	d, dir := startNotesFake(t)
	withKeyWriter(t, func(f *os.File, b []byte) error {
		if err := f.Chmod(0o644); err != nil {
			return err
		}
		_, err := f.Write(b)
		return err
	})
	if _, err := d.LLMSup.EnsureReady(context.Background()); err == nil || !strings.Contains(err.Error(), "mode") {
		t.Fatalf("err = %v, want a refusal naming the file mode", err)
	}
	if m := spawnStamps(t, dir); len(m) != 0 {
		t.Fatalf("ox-llm was spawned with a readable key file: %v", m)
	}
}

func TestCheckNotesKey(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good")
	_ = os.WriteFile(good, []byte("abc\n"), 0o600)
	blank := filepath.Join(dir, "blank")
	_ = os.WriteFile(blank, []byte("\n  \n"), 0o600)
	link := filepath.Join(dir, "link")
	_ = os.Symlink(good, link)
	for name, wantErr := range map[string]bool{good: false, blank: true, link: true, filepath.Join(dir, "none"): true} {
		if err := checkNotesKey(name); (err != nil) != wantErr {
			t.Errorf("checkNotesKey(%s) = %v, want error %v", filepath.Base(name), err, wantErr)
		}
	}
}

// The run dir holds the key: only this user may enter it, whatever mode it
// was created with, and a link planted at the temp name is replaced, not
// followed.
// Mutation: internal/daemon/meetings.go writeNotesKey, delete the
// `os.Chmod(dir, 0o700)` call -> RED.
// Mutation: internal/daemon/meetings.go writeNotesKey, delete the
// `_ = os.Remove(tmp)` line -> RED (the exclusive create hits the link).
func TestTheKeyLivesInAPrivateDirAndIgnoresAPlantedLink(t *testing.T) {
	cfg := testCfg(t, t.TempDir())
	if err := os.MkdirAll(cfg.RunDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(t.TempDir(), "victim")
	if err := os.WriteFile(victim, []byte("untouched"), 0o600); err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(cfg.RunDir(), notesKeyFile)
	if err := os.Symlink(victim, key+".tmp"); err != nil {
		t.Fatal(err)
	}
	if err := writeNotesKey(key); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(cfg.RunDir()); err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("run dir = %v, %v; want mode 0700", st, err)
	}
	if got, _ := os.ReadFile(victim); string(got) != "untouched" {
		t.Fatalf("the planted link was followed: victim = %q", got)
	}
}

// An ox-llm that serves without requiring its key is a failed engine, and the
// child does not outlive the failed start.
// Mutation: internal/daemon/meetings.go newLLMSupervisor, delete the
// `Verify: notesVerifyAuth,` line -> RED (the open server becomes Ready).
func TestAServerRunningOpenIsAFailedStart(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "1")
	_, err := d.LLMSup.EnsureReady(context.Background())
	if err == nil || !strings.Contains(err.Error(), "running open") {
		t.Fatalf("err = %v, want the open server named", err)
	}
	marks := spawnStamps(t, dir)
	if len(marks) != 1 {
		t.Fatalf("spawn stamps = %v", marks)
	}
	pid, _ := strconv.Atoi(strings.TrimPrefix(filepath.Base(marks[0]), "llm-spawn-"))
	waitProcessGone(t, pid, "the open ox-llm")
	if st := d.LLMSup.Status(); st.LastErr == "" || st.State == "ready" {
		t.Fatalf("status = %+v, want a failed start", st)
	}
}

// The healthy path still works end to end with the checks in place: the key
// is accepted, a keyless probe is refused.
func TestAKeyedServerStartsAndAnswersWithItsKey(t *testing.T) {
	d, _ := startNotesFake(t)
	out, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	if err != nil || out == "" {
		t.Fatalf("complete = %q, %v", out, err)
	}
}

// The bearer the daemon sends is never blank.
// Mutation: internal/daemon/meetings.go notesKey, delete the `key == ""`
// branch -> RED (the daemon would send `Bearer ` and nothing would notice).
func TestTheDaemonRefusesABlankKey(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	if err := os.MkdirAll(d.Cfg.RunDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.Cfg.RunDir(), notesKeyFile), []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if k, err := d.notesKey(); err == nil {
		t.Fatalf("notesKey = %q, nil; want an error for a blank key", k)
	}
}

// A foreign process on the notes port: nothing is spawned and nothing that
// answers there is trusted with the meeting text; /status says port_blocked.
// Mutation: internal/daemon/meetings.go notesPrepare, delete the whole
// `net.Listen` check -> RED (ox-llm is spawned into the taken port).
func TestAForeignListenerOnTheNotesPortFailsTheStart(t *testing.T) {
	d, dir := startNotesFake(t)
	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(d.Cfg.NotesPort))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() { // a stranger that says /health is fine
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_, _ = c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
			_ = c.Close()
		}
	}()
	_, err = d.LLMSup.EnsureReady(context.Background())
	if err == nil || !strings.Contains(err.Error(), notesPortTaken) {
		t.Fatalf("err = %v, want the taken port named", err)
	}
	if m := spawnStamps(t, dir); len(m) != 0 {
		t.Fatalf("ox-llm was spawned into a taken port: %v", m)
	}
	if n := d.Status().Notes; n.Available || n.ReasonCode != config.NotesReasonPortBlocked {
		t.Fatalf("notes = %+v, want port_blocked", n)
	}
}

// --- the meeting dependencies are wired by the real initMeetings -----------

// Mutation: internal/daemon/meetings.go initMeetings, delete the
// `PieceSeconds: d.pieceSeconds(),` line -> RED.
// Mutation: internal/daemon/meetings.go initMeetings, change NotesReady's
// body to `return ""` -> RED.
// Mutation: internal/daemon/meetings.go initMeetings, change Before to
// `func(context.Context) error { return nil }` -> RED; deleting the
// `Before:` line -> RED.
func TestInitMeetingsWiresTheDependencies(t *testing.T) {
	discrete := newTestDaemonSTT(t, t.TempDir(), nil, nil, nil)
	if got := discrete.Meet.PieceSeconds; got != cpuPieceSeconds {
		t.Errorf("discrete GPU: PieceSeconds = %d, want %d", got, cpuPieceSeconds)
	}
	unified := newTestDaemonSTT(t, t.TempDir(), func(c *config.Config) { c.GPUMemory = config.GPUMemoryUnified }, nil, nil)
	if got := unified.Meet.PieceSeconds; got != meeting.DefaultPieceSeconds {
		t.Errorf("unified memory: PieceSeconds = %d, want %d", got, meeting.DefaultPieceSeconds)
	}

	// NotesReady follows NotesBlock — the daemon of testCfg has no ox-llm.
	if got := discrete.Meet.NotesReady(); got != config.NotesReasonEngineMissing {
		t.Errorf("no engine: NotesReady = %q, want %q", got, config.NotesReasonEngineMissing)
	}
	dir := t.TempDir()
	model := filepath.Join(dir, config.NotesModelFile)
	ready := newTestDaemonSTT(t, dir, func(c *config.Config) {
		c.NotesBin, c.NotesPort, c.NotesModel = os.Args[0], testutil.FreePort(t), model
	}, nil, nil)
	if got := ready.Meet.NotesReady(); got != config.NotesReasonModelMissing {
		t.Errorf("no model: NotesReady = %q, want %q", got, config.NotesReasonModelMissing)
	}
	if err := os.WriteFile(model, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := ready.Meet.NotesReady(); got != "" {
		t.Errorf("model present: NotesReady = %q, want none", got)
	}

	// Before is the dictation yield: it waits while a dictation is in flight
	// and returns at once when the Mac is quiet.
	if ready.Meet.Before == nil {
		t.Fatal("Before is not wired")
	}
	ready.inflight.Add(1)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if err := ready.Meet.Before(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Before during a dictation = %v, want it to wait until the context ends", err)
	}
	ready.inflight.Add(-1)
	ready.lastInteractiveEnd.Store(0)
	if err := ready.Meet.Before(context.Background()); err != nil {
		t.Errorf("Before on a quiet Mac = %v", err)
	}
}

// --- start and shutdown ----------------------------------------------------

func finishedMeeting(t *testing.T, d *Daemon) string {
	t.Helper()
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	writeTone(t, filepath.Join(dir, meeting.MePCM), 5)
	if _, err := d.Meet.Finish(m.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	return m.ID
}

func meetingState(t *testing.T, d *Daemon, id string) meeting.Status {
	t.Helper()
	m, err := d.Meet.Store.Load(id)
	if err != nil {
		t.Fatal(err)
	}
	return m.Status
}

// Shutdown stops the meeting runner and the notes engine: a daemon told to
// stop must not keep working on a meeting or keep a 4-7 GB model child alive.
// Mutation: internal/daemon/service.go Shutdown, delete `d.StopMeetings()` ->
// RED (the second meeting is processed after Shutdown).
// Mutation: internal/daemon/service.go Shutdown, delete
// `d.LLMSup.Shutdown()` -> RED (the ox-llm child is still alive).
func TestShutdownStopsTheRunnerAndLeavesNoNotesChild(t *testing.T) {
	d, dir := startNotesFake(t)
	d.StartMeetings()
	first := finishedMeeting(t, d)
	testutil.WaitFor(t, 10*time.Second, func() bool { return meetingState(t, d, first) == meeting.StatusDone }, "the runner to finish a meeting")
	if _, err := d.LLMSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	marks := spawnStamps(t, dir)
	if len(marks) != 1 {
		t.Fatalf("spawn stamps = %v", marks)
	}
	pid, _ := strconv.Atoi(strings.TrimPrefix(filepath.Base(marks[0]), "llm-spawn-"))
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })

	d.Shutdown()

	waitProcessGone(t, pid, "the ox-llm child after Shutdown")
	second := finishedMeeting(t, d)
	time.Sleep(400 * time.Millisecond)
	if got := meetingState(t, d, second); got != meeting.StatusQueued {
		t.Fatalf("a meeting queued after Shutdown is %q: the runner is still running", got)
	}
}

// --- the model download belongs to the daemon ------------------------------

// installFixture is a daemon that can download the notes model by the script
// body given; the model is not on disk.
func installFixture(t *testing.T, script string) *Daemon {
	t.Helper()
	d, _ := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin, c.NotesPort = bin, testutil.FreePort(t)
		c.NotesModel = filepath.Join(c.Home, "models", config.NotesModelFile)
	})
	_ = os.MkdirAll(d.Cfg.Home, 0o755)
	if err := os.WriteFile(filepath.Join(d.Cfg.Home, fetchModelsScript), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

func readPid(t *testing.T, path string) int {
	t.Helper()
	var pid int
	testutil.WaitFor(t, 5*time.Second, func() bool {
		raw, err := os.ReadFile(path)
		if err != nil {
			return false
		}
		pid, err = strconv.Atoi(strings.TrimSpace(string(raw)))
		return err == nil
	}, "the fetch script to write "+filepath.Base(path))
	return pid
}

// Shutdown ends a running download — the fetch and the curl under it — and
// does not wait for it to finish by itself.
// Mutation: internal/daemon/meetings.go InstallNotesModel, change
// exec.CommandContext(d.notes.ctx, ...) to exec.Command(...) -> RED
// (Shutdown hangs on the download).
// Mutation: internal/daemon/service.go Shutdown, delete
// `d.StopNotesInstall()` -> RED (the fetch is still alive).
// Mutation: internal/daemon/meetings.go InstallNotesModel, change the
// cmd.Cancel body to `return cmd.Process.Kill()` -> RED (curl survives).
func TestShutdownKillsTheModelDownloadAndItsChildren(t *testing.T) {
	pids := filepath.Join(t.TempDir(), "pids")
	_ = os.MkdirAll(pids, 0o755)
	body := "#!/bin/sh\necho $$ > '" + pids + "/script'\nsleep 600 &\necho $! > '" + pids + "/curl'\nwait\n"
	d := installFixture(t, body)
	if err := d.InstallNotesModel(); err != nil {
		t.Fatal(err)
	}
	script, curl := readPid(t, filepath.Join(pids, "script")), readPid(t, filepath.Join(pids, "curl"))
	t.Cleanup(func() { _ = syscall.Kill(script, syscall.SIGKILL); _ = syscall.Kill(curl, syscall.SIGKILL) })

	done := make(chan struct{})
	go func() { d.Shutdown(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Shutdown is waiting for the download to finish by itself")
	}
	waitProcessGone(t, script, "the fetch script")
	waitProcessGone(t, curl, "the download under it")
	if d.notesInstalling() != 0 {
		t.Fatal("the download is still reported as running")
	}
	if err := d.InstallNotesModel(); err == nil {
		t.Fatal("a download must not start once the daemon is shutting down")
	}
}

// A second daemon (after a restart, with the first one's fetch still
// running) must not start a second writer on the same .part file: the lock
// is held by the fetch itself, not only by the daemon that started it.
// Mutation: internal/daemon/meetings.go InstallNotesModel, delete the
// `cmd.ExtraFiles = ...` line -> RED (the lock dies with the daemon's copy).
// Mutation: internal/daemon/meetings.go lockPart, delete the syscall.Flock
// block -> RED (a second writer is let in).
func TestADownloadInFlightBlocksASecondWriter(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\nsleep 600\n")
	lockPath := d.Cfg.NotesModel + ".part.lock"
	if err := d.InstallNotesModel(); err != nil {
		t.Fatal(err)
	}
	// The daemon has let go of its descriptor; the fetch still holds the lock.
	if f, err := lockPart(lockPath); err == nil {
		_ = f.Close()
		t.Fatal("the lock is free while the fetch runs: a second daemon could start a second writer")
	}
	// A second daemon with its own state is refused.
	other := installFixture(t, "#!/bin/sh\nexit 0\n")
	other.Cfg.Home, other.Cfg.NotesModel = d.Cfg.Home, d.Cfg.NotesModel
	if err := other.InstallNotesModel(); err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("second daemon: err = %v, want a refusal", err)
	}
	d.StopNotesInstall()
	f, err := lockPart(lockPath)
	if err != nil {
		t.Fatalf("the lock is still held after the download ended: %v", err)
	}
	_ = f.Close()
}

// --- disk space ------------------------------------------------------------

func withFreeBytes(t *testing.T, f func(string) (int64, error)) {
	t.Helper()
	old := freeBytes
	freeBytes = f
	t.Cleanup(func() { freeBytes = old })
}

// Mutation: internal/daemon/meetings.go checkNotesDisk, change `free < need`
// to `false` -> RED.
// Mutation: internal/daemon/meetings.go checkNotesDisk, delete the
// `need -= min(...)` line -> RED (a resumable .part is counted twice).
// Mutation: internal/daemon/meetings.go checkNotesDisk, return an error for
// a statfs failure -> RED.
func TestNotesDiskCheck(t *testing.T) {
	const total = int64(config.NotesModelBytes + notesDiskMargin)
	d := installFixture(t, "#!/bin/sh\nexit 0\n")
	wait := func() {
		testutil.WaitFor(t, 5*time.Second, func() bool { return d.notesInstalling() == 0 }, "the download to end")
	}

	withFreeBytes(t, func(string) (int64, error) { return total - 1, nil })
	if err := d.InstallNotesModel(); err == nil || !strings.Contains(err.Error(), "free disk space") {
		t.Fatalf("one byte short: err = %v, want a disk-space refusal", err)
	}
	withFreeBytes(t, func(string) (int64, error) { return total, nil })
	if err := d.InstallNotesModel(); err != nil {
		t.Fatalf("exactly enough: %v", err)
	}
	wait()

	// A 1 GiB .part is already on disk: only the rest must fit.
	part := d.Cfg.NotesModel + ".part"
	if err := os.WriteFile(part, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(part, 1<<30); err != nil {
		t.Fatal(err)
	}
	withFreeBytes(t, func(string) (int64, error) { return total - 1<<30 - 1, nil })
	if err := d.InstallNotesModel(); err == nil {
		t.Fatal("one byte short of the rest: want a refusal")
	}
	withFreeBytes(t, func(string) (int64, error) { return total - 1<<30, nil })
	if err := d.InstallNotesModel(); err != nil {
		t.Fatalf("the rest fits next to the .part: %v", err)
	}
	wait()

	// Free space that cannot be read does not block the download, and says so.
	withFreeBytes(t, func(string) (int64, error) { return 0, errors.New("statfs: boom") })
	if err := d.InstallNotesModel(); err != nil {
		t.Fatalf("unreadable free space: %v", err)
	}
	wait()
	if !testLogSaw(t, "cannot read the free disk space") {
		t.Fatal("the skipped check was not logged")
	}
}

// --- the failure words ------------------------------------------------------

// A fetch's progress meter redraws with carriage returns; the failure shown
// to the user keeps curl's own words and none of the meter.
// Mutation: internal/daemon/meetings.go installTail, delete the
// `strings.LastIndex(...)` redraw cut -> RED.
func TestInstallErrorCarriesCurlsWordsNotTheMeter(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\nprintf '  1  100M\\r  2  100M\\r  3  100M\\rcurl: (22) The requested URL returned error: 404\\n' >&2\nexit 22\n")
	if err := d.InstallNotesModel(); err != nil {
		t.Fatal(err)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool { return d.notesInstalling() == 0 }, "the download to fail")
	got := d.Status().Notes.InstallErr
	if !strings.Contains(got, "returned error: 404") || strings.ContainsAny(got, "\r") || strings.Contains(got, "100M") {
		t.Fatalf("install_error = %q, want curl's error and no progress meter", got)
	}
}

// A failed download carries a stable code beside curl's words: the window shows its own sentence for the code and
// never the English text. The codes are the ones the fetch can produce: no network, a full disk, a file that does not
// match its checksum, anything else.
// Mutations: internal/daemon/meetings.go notesStatus, delete `InstallCode: icode` -> RED (every row);
// installFailureCode, delete the "No space left" arm -> RED (disk_full rows); the "checksum mismatch" arm -> RED.
func TestAFailedDownloadHasAStableCode(t *testing.T) {
	cases := []struct{ name, stderr, want string }{
		{"no network", "curl: (6) Could not resolve host: huggingface.co", "network"},
		{"refused", "curl: (7) Failed to connect to huggingface.co port 443", "network"},
		{"server error", "curl: (22) The requested URL returned error: 503", "network"},
		{"curl cannot write", "curl: (23) Failure writing output to destination", "disk_full"},
		{"disk full", "mv: write error: No space left on device", "disk_full"},
		{"checksum", "checksum mismatch for qwen.gguf: got aa, want bb", "checksum"},
		{"anything else", "something unexpected", "other"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := installFixture(t, "#!/bin/sh\nprintf '%s\\n' '"+tc.stderr+"' >&2\nexit 1\n")
			if err := d.InstallNotesModel(); err != nil {
				t.Fatal(err)
			}
			testutil.WaitFor(t, 5*time.Second, func() bool { return d.notesInstalling() == 0 }, "the download to fail")
			n := d.Status().Notes
			if n.InstallErr == "" || n.InstallCode != tc.want {
				t.Fatalf("install_error %q, install_error_code %q; want a code %q", n.InstallErr, n.InstallCode, tc.want)
			}
			raw, _ := json.Marshal(n)
			if !strings.Contains(string(raw), `"install_error_code":"`+tc.want+`"`) {
				t.Fatalf("status JSON = %s", raw)
			}
		})
	}
}

// --- refusals ---------------------------------------------------------------

// A model on disk is "already installed" even when the notes are blocked for
// another reason (here: the port) — not a second download over it.
// Mutation: internal/daemon/meetings.go InstallNotesModel, replace the
// os.Stat(d.Cfg.NotesModel) test with `code == ""` -> RED.
func TestInstallRefusesWhenTheModelIsThereButNotesAreBlockedElsewhere(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\nexit 0\n")
	if err := os.MkdirAll(filepath.Dir(d.Cfg.NotesModel), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(d.Cfg.NotesModel, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.Cfg.NotesPortBlocked = true
	if code, _ := d.Cfg.NotesBlock(); code != config.NotesReasonPortBlocked {
		t.Fatalf("setup: block = %q", code)
	}
	if err := d.InstallNotesModel(); err == nil || !strings.Contains(err.Error(), "already installed") {
		t.Fatalf("err = %v, want \"already installed\"", err)
	}
}

// Every code installFailureCode can return, but the catch-all, has its sentence in the app. The codes are read from the
// function's return statements, so a new one cannot be added without a row in NotesWriterState.downloadFailureKey.
// Mutation: MeetingWindowService.swift, delete `case "checksum": return .settingsNotesWriterDownloadChecksum` -> RED.
func TestEveryInstallFailureCodeHasASwiftSentence(t *testing.T) {
	swift, err := os.ReadFile("../../app/dictation/Sources/DictationCore/MeetingWindowService.swift")
	if err != nil {
		t.Fatal(err)
	}
	file, err := parser.ParseFile(token.NewFileSet(), "meetings.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var codes []string
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "installFailureCode" {
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if rs, ok := n.(*ast.ReturnStmt); ok {
					for _, r := range rs.Results {
						if lit, ok := r.(*ast.BasicLit); ok {
							v, _ := strconv.Unquote(lit.Value)
							codes = append(codes, v)
						}
					}
				}
				return true
			})
		}
	}
	if len(codes) < 4 {
		t.Fatalf("read only %d codes from installFailureCode: %v", len(codes), codes)
	}
	for _, c := range codes {
		if c != "other" && !strings.Contains(string(swift), `case "`+c+`":`) {
			t.Errorf("the install failure %q has no case in MeetingWindowService.swift", c)
		}
	}
}
