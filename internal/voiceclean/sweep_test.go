package voiceclean

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// mkScratch is a scratch directory as Run leaves it after a kill: marked, its lock free.
func mkScratch(t *testing.T, root, name string, age time.Duration) string {
	t.Helper()
	p := mkForeign(t, root, name, age)
	f, err := claimScratch(p)
	must(t, err)
	must(t, f.Close())
	old := time.Now().Add(-age)
	must(t, os.Chtimes(p, old, old))
	return p
}

// mkForeign is a directory with the right name and WAVs in it but no marker: the shell script's, or a user's.
func mkForeign(t *testing.T, root, name string, age time.Duration) string {
	t.Helper()
	p := filepath.Join(root, name)
	must(t, os.Mkdir(p, 0o700))
	must(t, os.WriteFile(filepath.Join(p, "src.wav"), []byte("x"), 0o600))
	old := time.Now().Add(-age)
	must(t, os.Chtimes(p, old, old))
	return p
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func TestSweepStaleTakesOnlyOldScratchDirsOfThisTool(t *testing.T) {
	root := t.TempDir()
	stale := mkScratch(t, root, "voice-clean.abc123", 7*time.Hour)
	fresh := mkScratch(t, root, "voice-clean.def456", time.Hour)
	other := mkScratch(t, root, "other-tool.abc123", 7*time.Hour)
	bare := mkScratch(t, root, "voice-clean.", 7*time.Hour)
	noDot := mkScratch(t, root, "voice-cleanX", 7*time.Hour)
	file := filepath.Join(root, "voice-clean.file")
	must(t, os.WriteFile(file, []byte("x"), 0o600))
	must(t, os.Chtimes(file, time.Now().Add(-7*time.Hour), time.Now().Add(-7*time.Hour)))
	// the shell script's scratch dir and a user's notes: right name and age, no marker
	script := mkForeign(t, root, "voice-clean.Xy12Zk", 7*time.Hour)
	notes := mkForeign(t, root, "voice-clean.notes", 7*time.Hour)
	// a link named like a scratch dir, aimed at a directory that must survive
	target := mkScratch(t, t.TempDir(), "precious", 7*time.Hour)
	link := filepath.Join(root, "voice-clean.link")
	must(t, os.Symlink(target, link))

	got := SweepStale(root, StaleScratchAge)
	if len(got) != 1 || got[0] != stale {
		t.Fatalf("removed %v, want only %s", got, stale)
	}
	if exists(stale) {
		t.Error("the stale directory is still there")
	}
	for _, p := range []string{fresh, other, bare, noDot, file, link, target, script, notes, filepath.Join(script, "src.wav")} {
		if !exists(p) {
			t.Errorf("%s was removed", p)
		}
	}
	if !exists(filepath.Join(target, "src.wav")) {
		t.Error("the link target's content was removed")
	}
}

// A directory of another user is left alone. The uid is faked (the test cannot chown): the sweep is told it runs as a
// different user, so the directory's real owner is a foreign one.
func TestSweepStaleLeavesAnotherUsersDir(t *testing.T) {
	root := t.TempDir()
	p := mkScratch(t, root, "voice-clean.abc123", 7*time.Hour)
	if got := sweepStale(root, StaleScratchAge, time.Now(), os.Getuid()+1); len(got) != 0 || !exists(p) {
		t.Fatalf("a foreign directory was taken: %v", got)
	}
	if got := sweepStale(root, StaleScratchAge, time.Now(), os.Getuid()); len(got) != 1 || exists(p) {
		t.Fatalf("the own directory was not taken: %v", got)
	}
}

func TestSweepStaleMissingDirIsNothing(t *testing.T) {
	if got := SweepStale(filepath.Join(t.TempDir(), "nope"), StaleScratchAge); len(got) != 0 {
		t.Fatal(got)
	}
}

// A run holds the lock on its marker; a directory older than the threshold whose lock is held is a live run's (the
// wall clock may have jumped, or a second serve is running) and stays; once the lock is released it goes.
func TestSweepStaleKeepsADirWhoseLockIsHeld(t *testing.T) {
	root := t.TempDir()
	p := filepath.Join(root, "voice-clean.live01")
	must(t, os.Mkdir(p, 0o700))
	lock, err := claimScratch(p)
	must(t, err)
	old := time.Now().Add(-7 * time.Hour)
	must(t, os.Chtimes(p, old, old))
	if got := SweepStale(root, StaleScratchAge); len(got) != 0 || !exists(p) {
		t.Fatalf("a live run's directory was taken: %v", got)
	}
	must(t, lock.Close())
	if got := SweepStale(root, StaleScratchAge); len(got) != 1 || exists(p) {
		t.Fatalf("the released directory was not taken: %v", got)
	}
}

// A marker that is a link, or a directory in its place, is not ours.
func TestSweepStaleIgnoresAFakeMarker(t *testing.T) {
	root := t.TempDir()
	p := mkForeign(t, root, "voice-clean.fake01", 7*time.Hour)
	must(t, os.Symlink(filepath.Join(p, "src.wav"), filepath.Join(p, markerName)))
	if got := SweepStale(root, StaleScratchAge); len(got) != 0 || !exists(p) {
		t.Fatalf("a link as marker was accepted: %v", got)
	}
}

// Run itself marks and locks its scratch dir while it works.
func TestRunScratchDirIsMarkedAndLockedWhileRunning(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 48000, 1)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 1, fakeEngine(t, "1"))
	// while the engine runs, sweep the scratch root as if it were two days later with no age limit: the live run's
	// dir (marker locked) must survive
	var swept []string
	o.Run = func(ctx context.Context, bin string, args []string) ([]byte, error) {
		if ToolOf(ctx) == ToolEngine {
			swept = sweepStale(o.TempDir, 0, time.Now().Add(48*time.Hour), os.Getuid())
		}
		return execRunner(ctx, bin, args)
	}
	mustRun(t, o)
	if len(swept) != 0 {
		t.Fatalf("a running cleanup's scratch dir was swept: %v", swept)
	}
}
