package daemon

import (
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

func ptr[T any](v T) *T { return &v }

func startedProducer(t *testing.T, f *fakePorts) *producer {
	t.Helper()
	p := newProducer(f)
	p.start()
	t.Cleanup(func() { p.shutdown() })
	return p
}

func waitTerminal(t *testing.T, p *producer, id string) vproject.Summary {
	t.Helper()
	var s vproject.Summary
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		var err error
		if s, err = p.status(id); err != nil {
			t.Fatal(err)
		}
		switch s.Status {
		case vproject.StatusDone, vproject.StatusReview, vproject.StatusFailed, vproject.StatusCancelled, vproject.StatusInterrupted:
			// the job is over only once the producer released it
			p.mu.Lock()
			busy := p.cur != nil
			p.mu.Unlock()
			if !busy {
				return s
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("job %s still %s", id, s.Status)
	return s
}

func reelInput(t *testing.T) produceInput {
	return produceInput{Script: "Первое предложение. Второе.\n\nТретье.", Voice: "nar", Seed: ptr(int64(5)),
		OutPath: filepath.Join(t.TempDir(), "v.wav")}
}

// Create -> done; resume renders nothing (Q3); edit renders one take (Q2).
// Mutation: skip the sidecar lookup in taker.take -> resume hears again -> RED.
func TestProduceLifecycle(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusDone || got.Outputs.WAV == "" {
		t.Fatalf("%+v", got)
	}
	renders, hears := len(f.renders), f.hears
	if renders != 2 {
		t.Fatalf("renders %d, want 2 (one per chunk)", renders)
	}
	if _, err := p.resume(s.ID, false); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	if len(f.renders) != renders || f.hears != hears {
		t.Fatalf("resume rendered %d, heard %d", len(f.renders)-renders, f.hears-hears)
	}
	if _, err := p.chunk(s.ID, 1, chunkOp{Action: opEdit, Text: "Третье, исправленное."}); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	if len(f.renders) != renders+1 {
		t.Fatalf("edit rendered %d takes, want 1", len(f.renders)-renders)
	}
}

// A chunk failing every attempt ends in review; the file is still made.
// Mutation: return an error instead of settling to the best take -> failed -> RED.
func TestProduceReviewNotFailed(t *testing.T) {
	f := newFakePorts(t)
	for i := 0; i < 3; i++ {
		f.heard[i] = "совсем другие слова звучат здесь"
	}
	p := startedProducer(t, f)
	in := reelInput(t)
	in.Script = "Сохраните это видео, чтобы не забыть."
	s, err := p.create(in)
	if err != nil {
		t.Fatal(err)
	}
	got := waitTerminal(t, p, s.ID)
	if got.Status != vproject.StatusReview || got.Chunks[0].Status != vproject.ChunkReview || len(got.Chunks[0].Reasons) == 0 || got.Outputs.WAV == "" {
		t.Fatalf("%+v", got)
	}
	if len(f.renders) != 3 || f.renders[2].Cfg != lastAttemptCfg {
		t.Fatalf("renders %d, last cfg %v", len(f.renders), f.renders[len(f.renders)-1].Cfg)
	}
}

// A first take that is silent but transcribes perfectly must not be the
// fallback pick over an audible one: the audible take is chosen, and a chunk
// whose every take is silent is review, not a failed job (#154 amendment 3).
// Mutation: produce.go better, drop the silent preference -> the silent take wins -> RED.
func TestSilentTakeIsNotTheFallback(t *testing.T) {
	f := newFakePorts(t)
	f.silentAt[0] = true
	f.heard[1], f.heard[2] = "совсем другие слова звучат здесь", "совсем другие слова звучат"
	p := startedProducer(t, f)
	in := reelInput(t)
	in.Script = "Сохраните это видео, чтобы не забыть."
	s, err := p.create(in)
	if err != nil {
		t.Fatal(err)
	}
	got := waitTerminal(t, p, s.ID)
	m, lerr := vproject.Load(filepath.Join(f.home, produceDir, s.ID))
	if lerr != nil || got.Status != vproject.StatusReview || got.Chunks[0].Status != vproject.ChunkReview {
		t.Fatalf("%v %+v", lerr, got)
	}
	if pick := m.Chunks[0].Pick; pick == m.Chunks[0].Takes[0].Key {
		t.Fatalf("the silent take %s was picked over an audible one", pick)
	}
}

// Mutation: produce_assemble.go add, drop the ChunkReview exception -> the job fails -> RED.
func TestAllSilentChunkIsReviewAndStillAssembles(t *testing.T) {
	f := newFakePorts(t)
	f.silentAt[0], f.silentAt[1], f.silentAt[2] = true, true, true
	p := startedProducer(t, f)
	in := reelInput(t)
	in.Script = "Сохраните это видео, чтобы не забыть.\n\nВторой абзац звучит."
	s, err := p.create(in)
	if err != nil {
		t.Fatal(err)
	}
	got := waitTerminal(t, p, s.ID)
	if got.Status != vproject.StatusReview || got.Chunks[0].Status != vproject.ChunkReview || got.Error != "" || got.Outputs.WAV == "" {
		t.Fatalf("a silent chunk must end in review, got %+v", got)
	}
}

// A job whose every chunk is silent has nothing to publish: it fails in plain words.
func TestEverySilentJobFailsInPlainWords(t *testing.T) {
	f := newFakePorts(t)
	for i := 0; i < 3; i++ {
		f.silentAt[i] = true
	}
	p := startedProducer(t, f)
	in := reelInput(t)
	in.Script = "Сохраните это видео, чтобы не забыть."
	s, _ := p.create(in)
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusFailed || !strings.Contains(got.Error, "silent") {
		t.Fatalf("%+v", got)
	}
}

// One job at a time: a second create answers busy with the running id;
// the engine never sees two requests at once (#137.1).
// Mutation: drop the busy check in launch -> two jobs run -> RED.
func TestProduceOneAtATime(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	_, err = p.create(reelInput(t))
	var be *busyError
	if !errors.As(err, &be) || be.id != s.ID {
		t.Fatalf("second create: %v", err)
	}
	close(f.block)
	waitTerminal(t, p, s.ID)
	if f.maxInFlight != 1 {
		t.Fatalf("max in flight %d", f.maxInFlight)
	}
}

// Cancel during a blocked render: the take finishes and is kept; the job
// stops before the next take (D11).
// Mutation: render under the job context and cancel it -> the take is lost -> RED.
func TestCancelKeepsInFlightTake(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	if err := p.cancel(s.ID); err != nil {
		t.Fatal(err)
	}
	close(f.block)
	got := waitTerminal(t, p, s.ID)
	if got.Status != vproject.StatusCancelled || len(f.renders) != 1 {
		t.Fatalf("%s after %d renders", got.Status, len(f.renders))
	}
	m, err := vproject.Load(filepath.Join(f.home, produceDir, s.ID))
	if err != nil || len(m.Chunks[0].Takes) != 1 {
		t.Fatalf("in-flight take not kept: %v %+v", err, m)
	}
}

// Shutdown stops a running job within the bound and leaves it interrupted.
// Mutation: drop p.stop() in shutdown -> the bound is exceeded -> RED.
func TestShutdownInterrupts(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	p := newProducer(f)
	p.start()
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	start := time.Now()
	if !p.shutdown() || time.Since(start) > stopBound {
		t.Fatal("shutdown exceeded its bound")
	}
	m, err := vproject.Load(filepath.Join(f.home, produceDir, s.ID))
	if err != nil || m.Status != vproject.StatusInterrupted {
		t.Fatalf("%v %+v", err, m)
	}
}

// Dictation and battery show up as statuses, and the producer waits.
// Mutation: never call onWait in the taker's quiet -> status never shows -> RED.
func TestWaitingStatuses(t *testing.T) {
	f := newFakePorts(t)
	f.quietWait = 300 * time.Millisecond
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	saw := false
	for i := 0; i < 50 && !saw; i++ {
		st, _ := p.status(s.ID)
		saw = st.Status == vproject.StatusWaitingForDictation
		time.Sleep(10 * time.Millisecond)
	}
	if !saw {
		t.Fatal("waiting_for_dictation never shown")
	}
	waitTerminal(t, p, s.ID)

	f2 := newFakePorts(t)
	f2.onBattery = true
	powerPoll = 20 * time.Millisecond
	t.Cleanup(func() { powerPoll = 30 * time.Second })
	p2 := startedProducer(t, f2)
	s2, err := p2.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if st, _ := p2.status(s2.ID); st.Status != vproject.StatusPausedOnBattery || len(f2.renders) != 0 {
		t.Fatalf("%s with %d renders", st.Status, len(f2.renders))
	}
	if _, err := p2.resume(s2.ID, true); err != nil {
		t.Fatal(err)
	}
	if got := waitTerminal(t, p2, s2.ID); got.Status != vproject.StatusDone {
		t.Fatalf("%+v", got)
	}
}

// A resume re-reads the voice: a re-recorded clip changes the basis and
// the chunks render again (D10). Mutation: keep Settings.VoiceSHA from
// creation in refresh -> no re-render -> RED.
func TestResumeRefreshesVoice(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	n := len(f.renders)
	f.voice.SHA = "re-recorded"
	if _, err := p.resume(s.ID, false); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	if len(f.renders) != 2*n {
		t.Fatalf("renders after re-record %d, want %d", len(f.renders)-n, n)
	}
}

// The seed in the manifest is the one the take carries, not base + attempt: a
// base seed at the top of the engine's range wraps (#149.8).
// Mutation: produce.go record, `ref.Seed = j.m.Settings.Seed + int64(ref.Attempt)` -> RED.
func TestSeedsComeFromTheTakeRef(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	in := reelInput(t)
	in.Script, in.Takes, in.Seed = "Сохраните это видео, чтобы не забыть.", 2, ptr(int64(maxVoxSeed))
	s, err := p.create(in)
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	m, err := vproject.Load(filepath.Join(f.home, produceDir, s.ID))
	if err != nil || len(m.Chunks[0].Takes) != 2 || len(f.renders) != 2 {
		t.Fatalf("%v %+v", err, m.Chunks[0].Takes)
	}
	for k, tk := range m.Chunks[0].Takes {
		if tk.Seed != f.renders[k].Seed {
			t.Errorf("take %d: manifest seed %d, engine was asked for %d", k, tk.Seed, f.renders[k].Seed)
		}
	}
	if f.renders[1].Seed != 0 {
		t.Fatalf("the wrapped seed was %d, want 0", f.renders[1].Seed)
	}
}

// Errors that carry absolute paths never reach the manifest's plain-words
// error or an answer (#154.5): WriteAtomic's, Contained's Lstat's, and a
// free-text one that names a path.
// Mutation: produce.go publicMessage, return err.Error() -> RED.
func TestPublicMessageHidesPaths(t *testing.T) {
	home := "/Users/someone/Library/Application Support/ox-say"
	dir := filepath.Join(home, "produce", "20261015-120000-a1b2c3")
	_, lstatErr := os.Lstat(filepath.Join(t.TempDir(), "missing"))
	containedErr := vproject.Contained(t.TempDir(), filepath.Join(t.TempDir(), "gone"))
	cases := map[string]error{
		"write":     &vproject.WriteError{Path: filepath.Join(dir, "manifest.json"), Err: syscall.EACCES},
		"lstat":     lstatErr,
		"contained": containedErr,
		"wrapped":   errors.New("assemble: stat " + filepath.Join(dir, "out", ".x.tmp-1") + ": boom"),
		"spaces":    errors.New("open " + filepath.Join(home, "produce", "x") + ": boom"),
	}
	for name, err := range cases {
		msg := publicMessage(err, home)
		for _, leak := range []string{"/Users", "/var/", "Application Support", "/produce/", "/private"} {
			if strings.Contains(msg, leak) {
				t.Errorf("%s: %q leaks %q", name, msg, leak)
			}
		}
		if msg == "" {
			t.Errorf("%s: empty message", name)
		}
	}
	if got := publicMessage(&vproject.WriteError{Path: "/a/b/c.wav", Err: syscall.ENOSPC}); got != errDiskFull.Error() {
		t.Errorf("ENOSPC: %q", got)
	}
}

// A failed job's manifest error is in plain words, with no path.
func TestFailedJobErrorHasNoPath(t *testing.T) {
	f := newFakePorts(t)
	f.normErr = errors.New("ffmpeg failed on " + filepath.Join(f.home, "produce", "x", "out", ".a.tmp-1.wav") + ": bad")
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	got := waitTerminal(t, p, s.ID)
	if got.Status != vproject.StatusFailed || got.Error == "" || strings.Contains(got.Error, f.home) {
		t.Fatalf("%+v", got)
	}
}

// DELETE with outputs removes only files the project proves are its own: a
// hand-edited manifest pointing at someone else's file removes nothing (#154.6).
// Mutation: produce_ops.go ownedPaths, drop the export-ID check -> the victim is deleted -> RED.
// Mutation: produce_ops.go ownedPaths, drop the recorded-vs-stem comparison -> RED.
func TestRemoveWithOutputsRefusesTamperedManifests(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	done := waitTerminal(t, p, s.ID)
	victimDir := t.TempDir()
	victim := filepath.Join(victimDir, "precious.wav")
	if err := os.WriteFile(victim, []byte("precious"), 0o644); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(f.home, produceDir, s.ID)
	edits := map[string]func(m *vproject.Manifest){
		"recorded output elsewhere": func(m *vproject.Manifest) { m.Outputs.WAV = victim },
		"out_path elsewhere": func(m *vproject.Manifest) {
			m.Settings.OutPath = victim
			m.Outputs = vproject.Outputs{WAV: victim}
		},
	}
	decoy := filepath.Join(victimDir, "decoy.wav") // an export of ANOTHER project sits beside it
	_ = os.WriteFile(decoy, []byte("precious"), 0o644)
	_ = os.WriteFile(filepath.Join(victimDir, "decoy.manifest.json"), []byte(`{"id":"20261015-120000-ffffff"}`), 0o644)
	edits["export names another project"] = func(m *vproject.Manifest) {
		m.Settings.OutPath = decoy
		m.Outputs = vproject.Outputs{WAV: decoy, SRT: filepath.Join(victimDir, "decoy.srt"), VTT: filepath.Join(victimDir, "decoy.vtt"),
			Words: filepath.Join(victimDir, "decoy.words.json"), Manifest: filepath.Join(victimDir, "decoy.manifest.json")}
	}
	for name, edit := range edits {
		m, _ := vproject.Load(dir)
		orig := *m
		edit(m)
		if err := m.Save(dir); err != nil {
			t.Fatal(err)
		}
		if err := p.remove(s.ID, true); err == nil {
			t.Errorf("%s: remove succeeded", name)
		}
		for _, keep := range []string{victim, decoy} {
			if _, err := os.Stat(keep); err != nil {
				t.Fatalf("%s: %s is gone", name, filepath.Base(keep))
			}
		}
		if _, err := os.Stat(dir); err != nil {
			t.Fatalf("%s: the project was removed despite the refusal", name)
		}
		if err := orig.Save(dir); err != nil {
			t.Fatal(err)
		}
	}
	// An honest project deletes its own five files.
	if err := p.remove(s.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(done.Outputs.WAV); !os.IsNotExist(err) {
		t.Fatalf("own output survived delete_outputs: %v", err)
	}
}

// A manifest in directory A that says it is project B is refused.
func TestManifestIDMustMatchItsDirectory(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	dir := filepath.Join(f.home, produceDir, s.ID)
	m, _ := vproject.Load(dir)
	m.ID = "20261015-120000-ffffff"
	if err := m.Save(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := p.status(s.ID); err == nil {
		t.Fatal("a manifest naming another project was served")
	}
}

// SweepTemp never runs on a running job's directory: a chunk op against the
// running project is refused as busy BEFORE anything is removed (#154.6).
// Mutation: produce_ops.go open, sweep the directory before the busy check -> RED.
func TestSweepOnlyBehindTheBusyCheck(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	temp := filepath.Join(f.home, produceDir, s.ID, vproject.TakesDir, ".live"+vproject.TempMark+"1")
	if err := os.WriteFile(temp, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	_ = os.Chtimes(temp, old, old)
	var be *busyError
	if _, err := p.chunk(s.ID, 0, chunkOp{Action: opRegenerate, Takes: 1}); !errors.As(err, &be) {
		t.Fatalf("chunk op on the running project: %v", err)
	}
	if _, err := os.Stat(temp); err != nil {
		t.Fatalf("a running job's temp file was swept: %v", err)
	}
	close(f.block)
	waitTerminal(t, p, s.ID)
}

// A start sweeps leftovers nobody has touched for tempSweepMinAge and spares
// fresh ones, whose writer (an orphaned ffmpeg) may still be alive.
// Mutation: produce.go launch, sweep with age 0 -> the fresh file goes -> RED.
// Mutation: produce.go launch, drop the sweep -> the stale file stays -> RED.
func TestStartSweepsStaleSparesFresh(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	out := filepath.Join(f.home, produceDir, s.ID, vproject.WorkDir)
	_ = os.MkdirAll(out, 0o700)
	stale, fresh := filepath.Join(out, ".a"+vproject.TempMark+"1"), filepath.Join(out, ".b"+vproject.TempMark+"2")
	for _, f := range []string{stale, fresh} {
		_ = os.WriteFile(f, []byte("x"), 0o600)
	}
	old := time.Now().Add(-2 * tempSweepMinAge)
	_ = os.Chtimes(stale, old, old)
	if _, err := p.resume(s.ID, false); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("the stale leftover stayed")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Errorf("a fresh file (possible live orphan writer) was removed: %v", err)
	}
}

// adapterFiles may name Daemon, but only as a method receiver; every other
// produce*.go file (the core) may not name it at all.
var adapterFiles = map[string]bool{"produce_wire.go": true, "produce_http.go": true, "produce_mcp.go": true}

// Fitness (D19): the core never names Daemon; the adapters only in receivers.
// Mutation: add a `d *Daemon` field to producer (produce.go) -> RED.
// Mutation: give portFuncs a `d *Daemon` field (produce_wire.go) -> RED.
func TestProducerUsesPortsOnly(t *testing.T) {
	files, _ := filepath.Glob("produce*.go")
	core := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		fset := token.NewFileSet()
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		allowed := map[*ast.Ident]bool{}
		if adapterFiles[f] {
			for _, decl := range af.Decls {
				if fd, ok := decl.(*ast.FuncDecl); ok && fd.Recv != nil {
					ast.Inspect(fd.Recv, func(n ast.Node) bool {
						if id, ok := n.(*ast.Ident); ok {
							allowed[id] = true
						}
						return true
					})
				}
			}
		} else {
			core++
		}
		ast.Inspect(af, func(n ast.Node) bool {
			if id, ok := n.(*ast.Ident); ok && id.Name == "Daemon" && !allowed[id] {
				t.Errorf("%s:%d names Daemon outside a method receiver", f, fset.Position(id.Pos()).Line)
			}
			return true
		})
	}
	if core < 4 {
		t.Fatalf("checked %d core producer files, want >= 4", core)
	}
}

// launch is the one place that decides who runs: two launches never overlap,
// whatever pre-checks the callers did.
// Mutation: produce.go launch, drop the `p.cur != nil` busy answer -> RED.
func TestLaunchRefusesASecondJob(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	other := &job{dir: t.TempDir(), m: &vproject.Manifest{ID: "20261015-120000-aaaaaa"}, regen: map[int]int{}}
	var be *busyError
	if _, err := p.launch(other); !errors.As(err, &be) || be.id != s.ID {
		t.Fatalf("second launch: %v", err)
	}
	close(f.block)
	waitTerminal(t, p, s.ID)
}

// A take that reached the disk but not the manifest (a crash between the two
// writes) is reused on resume: no render, no transcription.
// Mutation: produce_take.go take, skip the sidecar lookup -> resume hears again -> RED.
func TestResumeAfterCrashReusesStoredTake(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	renders, hears := len(f.renders), f.hears
	dir := filepath.Join(f.home, produceDir, s.ID)
	m, _ := vproject.Load(dir)
	m.Chunks[0].Takes, m.Chunks[0].Pick, m.Chunks[0].Status = nil, "", vproject.ChunkPending
	if err := m.Save(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := p.resume(s.ID, false); err != nil {
		t.Fatal(err)
	}
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusDone {
		t.Fatalf("%+v", got)
	}
	if len(f.renders) != renders || f.hears != hears {
		t.Fatalf("resume rendered %d, heard %d", len(f.renders)-renders, f.hears-hears)
	}
}
