package stt

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

func TestMain(m *testing.M) {
	testutil.FakeChildMain()
	os.Exit(m.Run())
}

// fakeOpts points Options at the test binary re-exec'd as the fake ox-stt
// (OXSAY_FAKE_STT=1) and creates the model files Transcribe stats. It
// returns the path of the fake's argv/start/end record log.
func fakeOpts(t *testing.T, dir string) (Options, string) {
	t.Helper()
	t.Setenv("OXSAY_FAKE_STT", "1")
	log := filepath.Join(dir, "stt.log")
	t.Setenv("OXSAY_FAKE_STT_LOG", log)
	model := filepath.Join(dir, "parakeet.bin")
	whisper := filepath.Join(dir, "whisper.bin")
	for _, m := range []string{model, whisper} {
		if err := os.WriteFile(m, []byte("fake"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return Options{
		Bin:          os.Args[0],
		Model:        model,
		WhisperModel: whisper,
		GPU:          "auto",
		Timeout:      30 * time.Second,
	}, log
}

// sttRuns parses the fake's log into per-run records.
type sttRun struct {
	id    string
	args  []string
	pid   int
	start int64
	end   int64
}

func sttRuns(t *testing.T, log string) []sttRun {
	t.Helper()
	data, err := os.ReadFile(log)
	if errors.Is(err, os.ErrNotExist) {
		return nil // the fake has not been spawned yet
	}
	if err != nil {
		t.Fatal(err)
	}
	runs := map[string]*sttRun{}
	var order []*sttRun
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "argv\t"); ok {
			id, args, _ := strings.Cut(rest, "\t")
			r := &sttRun{id: id, args: strings.Split(args, "\t")}
			runs[id] = r
			order = append(order, r)
			continue
		}
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		r := runs[f[1]]
		if r == nil {
			r = &sttRun{id: f[1]}
			runs[f[1]] = r
			order = append(order, r)
		}
		r.pid, _ = strconv.Atoi(f[2])
		ns, _ := strconv.ParseInt(f[3], 10, 64)
		switch f[0] {
		case "start":
			r.start = ns
		case "end":
			r.end = ns
		}
	}
	out := make([]sttRun, 0, len(order))
	for _, r := range order {
		out = append(out, *r)
	}
	return out
}

func hasArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

// A plain happy path guards the wiring the S-tests lean on: the fake's JSON
// is parsed into Result and argv carries the contract flags.
func TestTranscribeHappyPath(t *testing.T) {
	dir := t.TempDir()
	opts, log := fakeOpts(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	res, err := Transcribe(context.Background(), src, opts)
	if err != nil {
		t.Fatal(err)
	}
	if res.Text != "hello world." || res.Engine != "parakeet" {
		t.Fatalf("result = %+v", res)
	}
	if res.Language == nil || *res.Language != "en" {
		t.Fatalf("language = %v", res.Language)
	}
	if len(res.Segments) != 1 || len(res.Words) != 2 || res.Words[0].W != "hello" {
		t.Fatalf("segments/words = %+v", res)
	}
	runs := sttRuns(t, log)
	if len(runs) != 1 {
		t.Fatalf("runs = %d, want 1", len(runs))
	}
	args := runs[0].args
	for _, want := range []string{"-m", opts.Model, "-f", "--engine", "parakeet"} {
		if !hasArg(args, want) {
			t.Fatalf("argv %v missing %q", args, want)
		}
	}

	// whisper picks the other model and forwards -l/--prompt.
	opts.Engine = "whisper"
	opts.Language = "ru"
	opts.Prompt = "some context"
	if _, err := Transcribe(context.Background(), src, opts); err != nil {
		t.Fatal(err)
	}
	runs = sttRuns(t, log)
	args = runs[len(runs)-1].args
	for _, want := range []string{opts.WhisperModel, "--engine", "whisper", "-l", "ru", "--prompt", "some context"} {
		if !hasArg(args, want) {
			t.Fatalf("whisper argv %v missing %q", args, want)
		}
	}
}

// S1 — device choice: EngineBusy (TTS starting/ready) or GPU=off forces -ng;
// GPU=on always takes the GPU; auto+idle does too.
// Mutation: gpuAllowed always returns true (never appends -ng) -> RED.
func TestDeviceChoice(t *testing.T) {
	dir := t.TempDir()
	opts, log := fakeOpts(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	cases := []struct {
		name    string
		gpu     string
		busy    bool
		wantNG  bool
	}{
		{"auto + engine busy → -ng", "auto", true, true},
		{"auto + idle → GPU", "auto", false, false},
		{"on + busy → GPU", "on", true, false},
		{"off + idle → -ng", "off", false, true},
	}
	for _, c := range cases {
		opts.GPU = c.gpu
		opts.EngineBusy = func() bool { return c.busy }
		if _, err := Transcribe(context.Background(), src, opts); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		runs := sttRuns(t, log)
		args := runs[len(runs)-1].args
		if got := hasArg(args, "-ng"); got != c.wantNG {
			t.Fatalf("%s: -ng present = %v, want %v (argv %v)", c.name, got, c.wantNG, args)
		}
	}
}

// S2 — the request context owns the ox-stt child: cancel must kill it.
// Mutation: spawn ox-stt with context.Background() in Transcribe -> RED
// (Transcribe never returns after cancel).
func TestCancelKillsEngine(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_STT_BLOCK", "1")
	opts, log := fakeOpts(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := Transcribe(ctx, src, opts)
		done <- err
	}()

	// The fake stamps its pid at start; wait for it, then cancel.
	var pid int
	testutil.WaitFor(t, 5*time.Second, func() bool {
		for _, r := range sttRuns(t, log) {
			if r.start != 0 && r.pid != 0 {
				pid = r.pid
				return true
			}
		}
		return false
	}, "fake ox-stt to start")
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Transcribe error = %v, want context.Canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Transcribe did not return within 2 s of cancel — child outlived the request context")
	}
	// CommandContext reaps the child before Run returns; the pid must be
	// gone, not just signalled.
	if err := syscall.Kill(pid, 0); err == nil {
		t.Fatalf("fake ox-stt pid %d still alive after cancel", pid)
	} else if !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("kill(%d, 0) = %v", pid, err)
	}
}

// S3 — one transcription at a time: two concurrent calls must not overlap
// in the engine. The fake records start/end stamps per -f temp wav.
// Mutation: remove the semaphore acquire in Transcribe -> RED (intervals overlap).
func TestOneAtATime(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_STT_DELAY_MS", "300")
	opts, log := fakeOpts(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := Transcribe(context.Background(), src, opts)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}

	runs := sttRuns(t, log)
	if len(runs) != 2 {
		t.Fatalf("runs = %d, want 2", len(runs))
	}
	for i := range runs {
		if runs[i].start == 0 || runs[i].end == 0 {
			t.Fatalf("run %s missing start/end stamps", runs[i].id)
		}
	}
	a, b := runs[0], runs[1]
	if a.start < b.end && b.start < a.end {
		t.Fatalf("transcriptions overlapped: %s [%d,%d] vs %s [%d,%d]",
			a.id, a.start, a.end, b.id, b.start, b.end)
	}
}

// A queued transcription honours its own context: while the semaphore is
// held, a second caller's cancel returns ctx.Err() instead of running.
func TestQueuedHonoursContext(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_STT_DELAY_MS", "500")
	opts, _ := fakeOpts(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	first := make(chan error, 1)
	go func() {
		_, err := Transcribe(context.Background(), src, opts)
		first <- err
	}()
	// Give the first call time to acquire the semaphore.
	time.Sleep(100 * time.Millisecond)

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := Transcribe(ctx, src, opts); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("queued call err = %v, want context.DeadlineExceeded", err)
	}
	if err := <-first; err != nil {
		t.Fatal(err)
	}
}

// Input classification: relative path, missing file and an undecodable clip
// are InputError (400); an ox-stt exit 1 is EngineError (500); a missing
// model names scripts/fetch-models.sh.
func TestTranscribeErrors(t *testing.T) {
	dir := t.TempDir()
	opts, _ := fakeOpts(t, dir)

	if _, err := Transcribe(context.Background(), "rel/in.wav", opts); err == nil {
		t.Fatal("relative path accepted")
	} else {
		var iErr *InputError
		if !errors.As(err, &iErr) {
			t.Fatalf("relative path err = %v (%T), want InputError", err, err)
		}
	}

	missing := filepath.Join(dir, "missing.wav")
	if _, err := Transcribe(context.Background(), missing, opts); err == nil {
		t.Fatal("missing file accepted")
	} else {
		var iErr *InputError
		if !errors.As(err, &iErr) {
			t.Fatalf("missing file err = %v (%T), want InputError", err, err)
		}
	}

	garbage := filepath.Join(dir, "garbage.bin")
	if err := os.WriteFile(garbage, []byte("not audio at all"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Transcribe(context.Background(), garbage, opts); err == nil {
		t.Fatal("undecodable clip accepted")
	} else {
		var iErr *InputError
		if !errors.As(err, &iErr) {
			t.Fatalf("undecodable clip err = %v (%T), want InputError", err, err)
		}
	}

	src := testutil.WriteTinyWAV(t, dir, "ok.wav")
	opts.Model = filepath.Join(dir, "absent-model.bin")
	if _, err := Transcribe(context.Background(), src, opts); err == nil {
		t.Fatal("missing model accepted")
	} else if !strings.Contains(err.Error(), "scripts/fetch-models.sh") || !strings.Contains(err.Error(), "absent-model.bin") {
		t.Fatalf("missing-model error = %v, want file named + fetch-models.sh", err)
	}
	opts.Model = filepath.Join(dir, "parakeet.bin")

	// ox-stt exit 1 → EngineError.
	t.Setenv("OXSAY_FAKE_STT_EXIT", "1")
	if _, err := Transcribe(context.Background(), src, opts); err == nil {
		t.Fatal("engine exit 1 accepted")
	} else {
		var eErr *EngineError
		if !errors.As(err, &eErr) {
			t.Fatalf("engine exit 1 err = %v (%T), want EngineError", err, err)
		}
	}
}
