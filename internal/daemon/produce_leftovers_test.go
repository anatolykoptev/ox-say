package daemon

import (
	"context"
	"errors"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// #156.1: remove does not hold the producer lock across the delete; a launch
// meanwhile answers busy for that project.
// Mutation: produce_ops.go remove, hold p.mu for the whole call (lock first,
// defer unlock) -> active() blocks -> RED.
func TestRemoveDoesNotHoldTheLockWhileDeleting(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	entered, release := make(chan struct{}), make(chan struct{})
	orig := removeAll
	t.Cleanup(func() { removeAll = orig })
	removeAll = func(path string) error {
		close(entered)
		<-release
		return orig(path)
	}
	done := make(chan error, 1)
	go func() { done <- p.remove(s.ID, false) }()
	<-entered
	probe := make(chan error, 1)
	go func() {
		_ = p.active() // takes p.mu
		_, err := p.launch(&job{dir: filepath.Join(p.root, s.ID), m: &vproject.Manifest{ID: s.ID}, regen: map[int]int{}})
		probe <- err
	}()
	probed := false
	select {
	case err := <-probe:
		probed = true
		var be *busyError
		if !errors.As(err, &be) {
			t.Errorf("launch during remove: %v, want busy", err)
		}
	case <-time.After(2 * time.Second):
		t.Error("the producer lock is held across the delete")
	}
	close(release) // also unblocks a mutant that holds the lock, so cleanup cannot hang
	if !probed {
		<-probe
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(p.root, s.ID)); !os.IsNotExist(err) {
		t.Errorf("the project survived: %v", err)
	}
}

// #156.2: a create whose files cannot be written leaves no half-made project
// directory, and a project that has not run yet is resumable ("interrupted").
// Mutation: produce_ops.go makeProject, `fail` returns without p.discard -> RED.
// Mutation: makeProject, drop `m.Status = vproject.StatusInterrupted` -> RED.
func TestMakeProjectLeavesNothingOnFailure(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	bad := &vproject.Manifest{Version: vproject.Version, ID: vproject.NewID(time.Now()), Settings: vproject.Settings{Cfg: math.NaN()}}
	if _, err := p.makeProject(bad, "Текст."); err == nil {
		t.Fatal("a manifest that cannot be saved was accepted")
	}
	if _, err := os.Stat(filepath.Join(p.root, bad.ID)); !os.IsNotExist(err) {
		t.Errorf("a manifest-less directory was left: %v", err)
	}
	good := &vproject.Manifest{Version: vproject.Version, ID: vproject.NewID(time.Now().Add(time.Second))}
	dir, err := p.makeProject(good, "Текст.")
	if err != nil {
		t.Fatal(err)
	}
	m, err := vproject.Load(dir)
	if err != nil || m.Status != vproject.StatusInterrupted {
		t.Errorf("status of a project that has not run: %q (%v)", m.Status, err)
	}
}

// #156.3: a launch after shutdown began is refused (it could race wg.Wait).
// Mutation: produce.go launch, delete the p.ctx.Err() check -> RED.
// #156.13: a launch whose first save fails releases the job's context.
// Mutation: produce.go launch, delete j.stopWait() on the save error -> RED.
func TestLaunchRefusedAfterShutdownAndReleasesOnSaveFailure(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	j := &job{dir: filepath.Join(t.TempDir(), "missing"), m: &vproject.Manifest{ID: "20261015-120000-aaaaaa"}, regen: map[int]int{}}
	if _, err := p.launch(j); err == nil {
		t.Fatal("launch into a missing directory succeeded")
	}
	if j.ctx == nil || j.ctx.Err() == nil {
		t.Error("the context of a job that never ran was not released")
	}
	if p.active() != 0 {
		t.Error("a failed launch left the producer busy")
	}
	p.shutdown()
	if _, err := p.launch(&job{dir: t.TempDir(), m: &vproject.Manifest{ID: "20261015-120000-bbbbbb"}, regen: map[int]int{}}); !errors.Is(err, errProducerStopped) {
		t.Errorf("launch after shutdown: %v", err)
	}
}

// #156.5: pruneTakes never walks through a symlinked takes/.
// Mutation: produce.go pruneTakes, drop the Lstat check -> the stray file in the target is removed -> RED.
func TestPruneTakesIgnoresASymlinkedTakesDir(t *testing.T) {
	proj, elsewhere := t.TempDir(), t.TempDir()
	stray := filepath.Join(elsewhere, "precious.txt")
	if err := os.WriteFile(stray, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(proj, vproject.TakesDir)); err != nil {
		t.Fatal(err)
	}
	if _, err := pruneTakes(&job{dir: proj, m: &vproject.Manifest{}}); err == nil {
		t.Error("a symlinked takes/ was pruned without complaint")
	}
	if _, err := os.Stat(stray); err != nil {
		t.Errorf("pruneTakes followed the symlink: %v", err)
	}
}

// #156.10: after the person replaced the published WAV, the answer says to
// move the files, not "set overwrite" (resume has no such flag).
// Mutation: produce_assemble.go assemble, call checkOutputs directly instead of
// checkProjectOutputs -> the message names overwrite -> RED.
// #156.11: with the WAV deleted by hand the siblings do not block the next assembly.
// Mutation: produce_ops.go ownedPaths, treat a missing WAV as a failed proof -> RED.
func TestEditedOrMissingWAVOnReassembly(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	wav := j.m.Outputs.WAV
	if err := os.WriteFile(wav, []byte("edited by hand"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := p.assemble(j)
	if err == nil || !strings.Contains(err.Error(), "move or rename") || strings.Contains(err.Error(), "overwrite") {
		t.Errorf("edited WAV: %v", err)
	}
	if err := os.Remove(wav); err != nil {
		t.Fatal(err)
	}
	if err := p.assemble(j); err != nil {
		t.Errorf("siblings left after the WAV was deleted block the assembly: %v", err)
	}
}

// #180: an English script reaches the engine with its digits; an edit keeps the
// project's language; a Russian project still gets number words.
// Mutation: produce_ops.go chunk, editChunk(.., projectLanguage(j.m)) ->
// editChunk(.., "") -> the digits-only edit of the English project gets Russian
// words -> RED.
// Mutation: vscript markup.go Parse, `o.Language = ScriptLanguage(src)` removed
// -> "I am двадцать пять" -> RED (also vscript TestSpokenFollowsTheScriptLanguage).
func TestProduceLanguageGate(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"I am 25 years old.","voice":"nar","out_path":"`+out+`"}`)
	if got := f.renders[0].Text; got != "I am 25 years old." {
		t.Errorf("the engine was asked for %q", got)
	}
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", `{"action":"edit","text":"Now 30 are left."}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("edit: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := f.renders[len(f.renders)-1].Text; got != "Now 30 are left." {
		t.Errorf("after the edit the engine was asked for %q", got)
	}
	// An edit that is only digits is read in the project's language.
	rec = do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", `{"action":"edit","text":"2030."}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("edit: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := f.renders[len(f.renders)-1].Text; got != "2030." {
		t.Errorf("a digits-only edit of an English project: the engine was asked for %q", got)
	}

	f2 := newFakePorts(t)
	_, mux2 := produceMux(t, f2)
	createDone(t, mux2, `{"script":"Мне 25 лет.","voice":"nar","out_path":"`+filepath.Join(t.TempDir(), "r.wav")+`"}`)
	if got := f2.renders[0].Text; got != "Мне двадцать пять лет." {
		t.Errorf("Russian: the engine was asked for %q", got)
	}
}

// A restart gate asks active(): a delete in flight counts, or the daemon could
// be stopped mid-RemoveAll and leave a manifest-less directory.
// Mutation: produce.go active, drop `&& p.removing == ""` -> 0 during the delete -> RED.
func TestActiveCountsARemoveInFlight(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	if p.active() != 0 {
		t.Fatal("idle producer reports active")
	}
	entered, release := make(chan struct{}), make(chan struct{})
	orig := removeAll
	t.Cleanup(func() { removeAll = orig })
	removeAll = func(path string) error {
		close(entered)
		<-release
		return orig(path)
	}
	done := make(chan error, 1)
	go func() { done <- p.remove(s.ID, false) }()
	<-entered
	got := p.active()
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got != 1 {
		t.Errorf("active() = %d during a remove, want 1", got)
	}
	if p.active() != 0 {
		t.Error("active() stays 1 after the remove")
	}
}

// Every chunk's leading Russian cue is left out of the project language, not
// only the first's: an English project stays English on the edit path.
// Mutation: produce_ops.go projectLanguage, write c.Text without
// vscript.StripLeadingCues -> the edit reads "двадцать пять" -> RED.
func TestProjectLanguageIgnoresEveryChunksCue(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"I have 25 apples today.\n\n(шёпотом) And 30 pears tomorrow.","voice":"nar","out_path":"`+out+`"}`)
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", `{"action":"edit","text":"2030."}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("edit: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := f.renders[len(f.renders)-1].Text; got != "2030." {
		t.Errorf("edit in an English project with a later Russian cue: the engine was asked for %q", got)
	}
}

// #313.5: a script with no letters has no language of its own, so it is read in
// the configured one (OX_SAY_LANG), as the speak route reads it; with none
// configured it is Russian, as it always was. A script with letters ignores it.
// Mutation: produce_ops.go newManifest, drop the scriptOpts fallback (parse
// with pr.opts) -> "2030" becomes "две тысячи тридцать" under en -> RED.
// Mutation: produce_ops.go projectLanguage, the final `return p.ports.
// ConfiguredLanguage()` -> `return ""` -> the digits-only edit of an English
// digits-only project gets Russian words -> RED.
func TestProduceDigitOnlyScriptFollowsConfiguredLanguage(t *testing.T) {
	for _, c := range []struct{ lang, script, want string }{
		{"en", "2030", "2030"},
		{"ru", "2030", "две тысячи тридцать"},
		{"", "2030", "две тысячи тридцать"},
		{"en", "Мне 25 лет.", "Мне двадцать пять лет."},
		{"ru", "I am 25 years old.", "I am 25 years old."},
	} {
		f := newFakePorts(t)
		f.lang = c.lang
		_, mux := produceMux(t, f)
		id := createDone(t, mux, `{"script":"`+c.script+`","voice":"nar","out_path":"`+filepath.Join(t.TempDir(), "v.wav")+`"}`)
		if got := f.renders[0].Text; got != c.want {
			t.Errorf("OX_SAY_LANG=%q script %q: the engine was asked for %q, want %q", c.lang, c.script, got, c.want)
		}
		if c.script == "2030" {
			rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", `{"action":"edit","text":"2020"}`)
			if rec.Code != http.StatusAccepted {
				t.Fatalf("edit: %d %s", rec.Code, rec.Body)
			}
			waitDoneHTTP(t, mux, id)
			want := "2020"
			if c.lang != "en" {
				want = "две тысячи двадцать"
			}
			if got := f.renders[len(f.renders)-1].Text; got != want {
				t.Errorf("OX_SAY_LANG=%q edit: the engine was asked for %q, want %q", c.lang, got, want)
			}
		}
	}
}

// #165.2: a chunk the person accepted after listening is ok and carries no
// failure reasons (they stay on the take itself); a chunk that is still in
// review, including an unusable silent pick, keeps the pick's reasons.
// Mutation: produce.go settle, `if c.Status == vproject.ChunkOK {` -> `if false {`
// (the reasons stay on an accepted chunk) -> RED.
func TestSettleDropsReasonsOfAnAcceptedUserPick(t *testing.T) {
	failed := vproject.TakeRef{Key: "fail", Passed: false, WER: 0.4, Reasons: []string{"1 word differs"}}
	silent := vproject.TakeRef{Key: "mute", Passed: false, Reasons: []string{reasonSilent}}
	for name, tc := range map[string]struct {
		take       vproject.TakeRef
		userPick   bool
		wantStatus string
		wantReason bool
	}{
		"user pick of a failed take":  {failed, true, vproject.ChunkOK, false},
		"automatic fallback":          {failed, false, vproject.ChunkReview, true},
		"user pick of a silent take":  {silent, true, vproject.ChunkReview, true},
		"user pick of a passing take": {vproject.TakeRef{Key: "good", Passed: true}, true, vproject.ChunkOK, false},
	} {
		c := &vproject.Chunk{Takes: []vproject.TakeRef{tc.take}, Pick: tc.take.Key, UserPick: tc.userPick}
		settle(c)
		if c.Status != tc.wantStatus || (len(c.Reasons) > 0) != tc.wantReason {
			t.Errorf("%s: status %q reasons %v, want %q and reasons=%v", name, c.Status, c.Reasons, tc.wantStatus, tc.wantReason)
		}
		if len(c.Takes[0].Reasons) != len(tc.take.Reasons) {
			t.Errorf("%s: the take's own reasons were touched: %v", name, c.Takes[0].Reasons)
		}
	}
}

// #156.13: a cancel that arrives while the job waits for dictation AFTER a take
// was rendered still gates that take (it is kept), and the take is heard under
// "running", not under a stale "waiting_for_dictation".
// Mutation: produce.go quiet, drop the setStatus(running) on the error path
// (restore it only when err == nil) -> RED.
func TestStatusLeavesWaitingWhenACancelEndsTheWait(t *testing.T) {
	f := newFakePorts(t)
	inGate := make(chan struct{})
	f.quietFn = func(ctx context.Context, onWait func()) error {
		f.mu.Lock()
		rendered := len(f.renders) > 0
		f.mu.Unlock()
		if !rendered {
			return nil
		}
		onWait()
		close(inGate)
		<-ctx.Done()
		return ctx.Err()
	}
	p := startedProducer(t, f)
	statusAtHear := make(chan string, 1)
	f.hearHook = func() {
		p.mu.Lock()
		st := p.cur.m.Status
		p.mu.Unlock()
		select {
		case statusAtHear <- st:
		default:
		}
	}
	in := reelInput(t)
	in.Script = "Одно предложение."
	s, err := p.create(in)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-inGate:
	case <-time.After(10 * time.Second):
		t.Fatal("the job never waited for dictation after a render")
	}
	if err := p.cancel(s.ID); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-statusAtHear:
		if got != vproject.StatusRunning {
			t.Errorf("the rendered take was heard under status %q, want running", got)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the rendered take was dropped by the cancel instead of being gated")
	}
	waitTerminal(t, p, s.ID)
}
