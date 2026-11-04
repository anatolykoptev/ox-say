package voiceclean

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func mkScratch(t *testing.T, root, name string, age time.Duration) string {
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
	for _, p := range []string{fresh, other, bare, noDot, file, link, target} {
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
