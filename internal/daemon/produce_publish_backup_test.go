package daemon

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// The publish backs the previous set up by hard link instead of moving it
// aside (#418, review of b0396d7): the old file stays at its name until the
// burst renames over it, the backup name is one no sweep matches, and a crash
// at any stage loses no old file.

// backupsOf are the backup files beside stem.
func backupsOf(t *testing.T, j *job) []string {
	t.Helper()
	var out []string
	entries, _ := os.ReadDir(filepath.Dir(j.m.Settings.OutPath))
	for _, e := range entries {
		if strings.Contains(e.Name(), backupMark) {
			out = append(out, filepath.Join(filepath.Dir(j.m.Settings.OutPath), e.Name()))
		}
	}
	return out
}

// isPlace: the rename moves a staged temp onto one of the five published names.
func isPlace(j *job, from, to string) bool {
	if !strings.Contains(filepath.Base(from), vproject.TempMark) || strings.Contains(from, ".assembled") {
		return false
	}
	for _, ext := range outputExts {
		if to == assembledStem(j)+ext {
			return true
		}
	}
	return false
}

// crashAt runs fn, which must stop in a panic raised by the test's seam: the
// stand-in for a kill -9, power cut or unplugged drive at that point.
func crashAt(t *testing.T, fn func() error) {
	t.Helper()
	defer func() {
		if r := recover(); r != "crash" {
			t.Fatalf("expected the simulated crash, got %v", r)
		}
	}()
	_ = fn()
	t.Fatal("the publish finished without reaching the crash point")
}

// oldBytesSurvive fails when any old file's bytes are neither under its name
// nor in some backup.
func oldBytesSurvive(t *testing.T, j *job, before map[string]string) {
	t.Helper()
	var held []string
	for _, b := range backupsOf(t, j) {
		raw, _ := os.ReadFile(b)
		held = append(held, string(raw))
	}
	for ext, was := range before {
		raw, _ := os.ReadFile(assembledStem(j) + ext)
		found := string(raw) == was
		for _, h := range held {
			found = found || h == was
		}
		if !found {
			t.Errorf("the old %s is nowhere: not under its name, not in a backup", ext)
		}
	}
}

// A published name exists at every moment of a re-publish: the seams stat all
// five names before each rename and link and before each removal.
// Mutation: produce_assemble.go backupFile, `linkFile(src, b)` ->
// `renameFile(src, b)` (the old file moves aside) -> the name is absent at the
// next step -> RED.
func TestPublishNeverLeavesAPublishedNameAbsent(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	editForReassembly(j)
	stem := assembledStem(j)
	steps := 0
	check := func(op, a, b string) {
		steps++
		for _, ext := range outputExts {
			if _, err := os.Lstat(stem + ext); err != nil {
				t.Errorf("before %s %s -> %s: %s is absent: %v", op, filepath.Base(a), filepath.Base(b), ext, err)
			}
		}
	}
	origRename, origLink, origRemove := renameFile, linkFile, removeFile
	t.Cleanup(func() { renameFile, linkFile, removeFile = origRename, origLink, origRemove })
	renameFile = func(a, b string) error { check("rename", a, b); return origRename(a, b) }
	linkFile = func(a, b string) error { check("link", a, b); return origLink(a, b) }
	removeFile = func(a string) error { check("remove", a, ""); return origRemove(a) }
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	if steps < 2*len(outputExts) {
		t.Fatalf("only %d steps were observed", steps)
	}
	noTemps(t, filepath.Dir(stem))
}

// The same on the way back: a burst that fails keeps every name present while
// it rolls back.
func TestRollbackNeverLeavesAPublishedNameAbsent(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	before := outputSet(t, j)
	editForReassembly(j)
	stem := assembledStem(j)
	origRename := renameFile
	t.Cleanup(func() { renameFile = origRename })
	renameFile = func(a, b string) error {
		for _, ext := range outputExts {
			if _, err := os.Lstat(stem + ext); err != nil {
				t.Errorf("before rename %s -> %s: %s is absent: %v", filepath.Base(a), filepath.Base(b), ext, err)
			}
		}
		if b == stem+".wav" && strings.Contains(a, vproject.TempMark) {
			return errors.New("disk on fire")
		}
		return origRename(a, b)
	}
	if err := p.assemble(j); !errors.Is(err, errOutputsKept) {
		t.Fatal(err)
	}
	for e, was := range outputSet(t, j) {
		if was != before[e] {
			t.Errorf("%s changed", e)
		}
	}
}

// What the retreat-to-temp design did: the old file under a name the sweep
// reaps, with its old mtime. A backup must survive the sweep of the next
// publish, however old it is.
// Mutation: produce_assemble.go backupMark = vproject.TempMark -> the sweep
// deletes the only copy -> RED.
func TestSweepNeverTouchesABackup(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	editForReassembly(j)
	crashAt(t, func() error { // the first place of the burst: backups exist, nothing placed
		orig := renameFile
		defer func() { renameFile = orig }()
		renameFile = func(a, b string) error {
			if isPlace(j, a, b) {
				panic("crash")
			}
			return orig(a, b)
		}
		return p.assemble(j)
	})
	old := time.Now().Add(-48 * time.Hour)
	bs := backupsOf(t, j)
	if len(bs) != len(outputExts) {
		t.Fatalf("backups %v", bs)
	}
	for _, b := range bs {
		if err := os.Chtimes(b, old, old); err != nil {
			t.Fatal(err)
		}
	}
	sweepOutputTemps(assembledStem(j), 0)
	if got := backupsOf(t, j); len(got) != len(bs) {
		t.Fatalf("the sweep removed backups: %v of %v remain", got, bs)
	}
}

// A crash at each stage of a publish loses no old file, and the next
// successful publish leaves a clean folder: the five new files, no backup, no
// temp. The stages: backups made and nothing placed; some placed; all placed
// and the directory not yet synced; everything done but the backups not yet
// removed.
// Mutation: produce_assemble.go publish, drop the `stale` backups from the
// removal loop -> the leftovers of the crashed run stay -> RED (every stage).
func TestCrashAtAnyStageLosesNoOldFileAndTheNextPublishCleans(t *testing.T) {
	stages := []struct {
		name  string
		crash func(t *testing.T, j *job)
	}{
		{"after the backups", func(t *testing.T, j *job) {
			orig := renameFile
			t.Cleanup(func() { renameFile = orig })
			renameFile = func(a, b string) error {
				if isPlace(j, a, b) {
					panic("crash")
				}
				return orig(a, b)
			}
		}},
		{"after some placements", func(t *testing.T, j *job) {
			orig := renameFile
			n := 0
			t.Cleanup(func() { renameFile = orig })
			renameFile = func(a, b string) error {
				if isPlace(j, a, b) {
					if n++; n == 3 {
						panic("crash")
					}
				}
				return orig(a, b)
			}
		}},
		{"after all placements, before the sync", func(t *testing.T, j *job) {
			orig := syncOutputDir
			t.Cleanup(func() { syncOutputDir = orig })
			syncOutputDir = func(string) error { panic("crash") }
		}},
		{"after the manifest save, before the cleanup", func(t *testing.T, j *job) {
			orig := removeFile
			t.Cleanup(func() { removeFile = orig })
			removeFile = func(path string) error {
				if strings.Contains(path, backupMark) {
					panic("crash")
				}
				return orig(path)
			}
		}},
	}
	for _, st := range stages {
		t.Run(st.name, func(t *testing.T) {
			f := newFakePorts(t)
			p, j := assembleFixture(t, f)
			if err := p.assemble(j); err != nil {
				t.Fatal(err)
			}
			before := outputSet(t, j)
			editForReassembly(j)
			j.m.Settings.Overwrite = true // a crash before the manifest save leaves its WAV hash stale
			st.crash(t, j)
			crashAt(t, func() error { return p.assemble(j) })
			oldBytesSurvive(t, j, before)

			// The restart, some time later (the sweep spares fresh temps, which
			// may have a live writer): seams back to the real ones, a later publish.
			old := time.Now().Add(-time.Hour)
			dirEntries, _ := os.ReadDir(filepath.Dir(j.m.Settings.OutPath))
			for _, e := range dirEntries {
				if strings.Contains(e.Name(), vproject.TempMark) {
					_ = os.Chtimes(filepath.Join(filepath.Dir(j.m.Settings.OutPath), e.Name()), old, old)
				}
			}
			renameFile, syncOutputDir, removeFile = os.Rename, vproject.SyncDir, os.Remove
			if err := p.assemble(j); err != nil {
				t.Fatalf("the next publish: %v", err)
			}
			noTemps(t, filepath.Dir(j.m.Settings.OutPath))
			for _, ext := range outputExts {
				if _, err := os.Lstat(assembledStem(j) + ext); err != nil {
					t.Errorf("%s: %v", ext, err)
				}
			}
		})
	}
}

// Backups a crashed publish left are the only copy of the old set until a
// publish has succeeded: a publish that FAILS leaves them where they are.
// Mutation: produce_assemble.go publish, delete the `stale` backups right
// after listing them (before the burst) -> the old set is gone after the
// failure -> RED.
func TestStaleBackupsSurviveAFailedPublish(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	before := outputSet(t, j)
	editForReassembly(j)
	orig := renameFile
	t.Cleanup(func() { renameFile = orig })
	renameFile = func(a, b string) error {
		if isPlace(j, a, b) && strings.HasSuffix(b, ".vtt") {
			panic("crash")
		}
		return orig(a, b)
	}
	crashAt(t, func() error { return p.assemble(j) })
	stale := len(backupsOf(t, j))
	if stale == 0 {
		t.Fatal("setup: no backups left by the crash")
	}
	// The mixed set left by the crash: the person fixes nothing; the next
	// publish fails on every place.
	renameFile = func(a, b string) error {
		if isPlace(j, a, b) {
			return errors.New("read-only volume")
		}
		return orig(a, b)
	}
	j.m.Settings.Overwrite = true
	if err := p.assemble(j); !errors.Is(err, errOutputsKept) {
		t.Fatalf("the failing publish: %v", err)
	}
	if got := len(backupsOf(t, j)); got != stale {
		t.Fatalf("%d backups after the failed publish, %d before: the old set was touched", got, stale)
	}
	oldBytesSurvive(t, j, before)
}

// The backups go only after the directory is synced: new data durable, then
// old data gone.
// Mutation: produce_assemble.go publish, move the backup removal loop above
// the syncOutputDir call -> the backups are gone at the sync -> RED.
func TestBackupsAreRemovedOnlyAfterTheDirectorySync(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	editForReassembly(j)
	var atSync int
	orig := syncOutputDir
	t.Cleanup(func() { syncOutputDir = orig })
	syncOutputDir = func(dir string) error { atSync = len(backupsOf(t, j)); return orig(dir) }
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	if atSync != len(outputExts) {
		t.Fatalf("%d backups at the sync, want %d", atSync, len(outputExts))
	}
	if left := backupsOf(t, j); len(left) != 0 {
		t.Fatalf("backups left after a successful publish: %v", left)
	}
}

// The manifest is saved right after the burst, before the backups go: a stop
// at that point finds the new outputs recorded, not a manifest that names the
// old files while the new ones are in place.
// Mutation: produce_assemble.go publish, delete the j.m.Save call -> the
// manifest on disk still has the old sha at the first backup removal -> RED.
func TestManifestIsSavedRightAfterTheBurst(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	if err := j.m.Save(j.dir); err != nil {
		t.Fatal(err)
	}
	oldSHA := j.m.Outputs.WAVSHA256
	j.m.PendingLUFS, j.m.PendingStatus = ptr(-18.0), vproject.StatusDone
	editForReassembly(j)
	var seen *vproject.Manifest
	orig := removeFile
	t.Cleanup(func() { removeFile = orig })
	removeFile = func(path string) error {
		if seen == nil && strings.Contains(path, backupMark) {
			seen, _ = vproject.Load(j.dir)
		}
		return orig(path)
	}
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	if seen == nil || seen.Outputs.WAVSHA256 == oldSHA || seen.Outputs.WAVSHA256 == "" {
		t.Fatalf("at the first backup removal the saved manifest still names the old file: %+v", seen)
	}
	if seen.PendingLUFS != nil || seen.PendingStatus != "" {
		t.Fatalf("the saved manifest still carries the pending change: %v %q", seen.PendingLUFS, seen.PendingStatus)
	}
}

// A volume without hard links gets a copy of the same bytes and mtime: the
// re-publish succeeds there and cleans up, and a failed burst still restores
// the old bytes from the copies.
// Mutation: produce_assemble.go backupFile, the default branch returns the
// link error instead of copyBackup -> the re-publish fails on such a volume
// (the "publishes" case) -> RED.
func TestBackupFallsBackToACopyWithoutHardLinks(t *testing.T) {
	setup := func(t *testing.T) (*producer, *job, map[string]string, os.FileInfo) {
		f := newFakePorts(t)
		p, j := assembleFixture(t, f)
		if err := p.assemble(j); err != nil {
			t.Fatal(err)
		}
		before := outputSet(t, j)
		st, err := os.Stat(assembledStem(j) + ".srt")
		if err != nil {
			t.Fatal(err)
		}
		editForReassembly(j)
		origLink := linkFile
		t.Cleanup(func() { linkFile = origLink })
		linkFile = func(string, string) error { return syscall.ENOTSUP }
		return p, j, before, st
	}
	t.Run("publishes", func(t *testing.T) {
		p, j, before, _ := setup(t)
		if err := p.assemble(j); err != nil {
			t.Fatalf("a re-publish on a volume without hard links: %v", err)
		}
		if outputSet(t, j)[".srt"] == before[".srt"] {
			t.Error("the .srt was not replaced")
		}
		noTemps(t, filepath.Dir(assembledStem(j)))
	})
	t.Run("rolls back", func(t *testing.T) {
		p, j, before, old := setup(t)
		stem := assembledStem(j)
		origRename := renameFile
		t.Cleanup(func() { renameFile = origRename })
		renameFile = func(a, b string) error {
			if b == stem+".wav" && strings.Contains(a, vproject.TempMark) {
				return errors.New("disk on fire")
			}
			return origRename(a, b)
		}
		if err := p.assemble(j); !errors.Is(err, errOutputsKept) {
			t.Fatalf("%v", err)
		}
		for e, was := range outputSet(t, j) {
			if was != before[e] {
				t.Errorf("%s was not restored from its copy", e)
			}
		}
		if st, err := os.Stat(stem + ".srt"); err != nil || !st.ModTime().Equal(old.ModTime()) || st.Mode().Perm() != old.Mode().Perm() {
			t.Errorf("the restored .srt lost its mtime or mode: %v %v", st, err)
		}
		noTemps(t, filepath.Dir(stem))
	})
}

// A file that appeared at a placed name during the burst is not the burst's
// and is not removed or replaced by the rollback: the first publish places
// the .srt by link, someone puts their own file over it, then the next place
// fails. The user's file stays, the miss is reported as a restore problem.
// Mutation: produce_assemble.go undoBurst, drop the `foreign` check (treat
// every placed file as the burst's) -> the user's file is deleted -> RED.
func TestRollbackNeverRemovesAFileTheBurstDidNotCreate(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	var logBuf bytes.Buffer
	p.log = slog.New(slog.NewTextHandler(&logBuf, nil))
	stem := assembledStem(j)
	origLink := linkFile
	t.Cleanup(func() { linkFile = origLink })
	linkFile = func(a, b string) error {
		if b == stem+".vtt" { // the burst has placed the .srt; now the user replaces it
			mine := stem + ".srt.mine"
			if err := os.WriteFile(mine, []byte("MINE"), 0o600); err != nil {
				t.Error(err)
			}
			if err := os.Rename(mine, stem+".srt"); err != nil {
				t.Error(err)
			}
			return fs.ErrExist // a refused link: the name was taken (any other error falls back to a rename)
		}
		return origLink(a, b)
	}
	err := p.assemble(j)
	if !errors.Is(err, errOutputsBroken) {
		t.Fatalf("%v", err)
	}
	if raw, _ := os.ReadFile(stem + ".srt"); string(raw) != "MINE" {
		t.Fatalf("the user's file was removed or replaced: %q", raw)
	}
	if !strings.Contains(logBuf.String(), "v.srt was replaced by another program") {
		t.Fatalf("the log does not say what was left alone: %s", logBuf.String())
	}
}

// A destination that is not the project's own is never linked, copied or
// moved: the backup step looks only at replaceable names.
// Mutation: produce_assemble.go backupOutputs, drop the `!replaceable` guard
// -> the user's file is hard-linked to a backup name -> RED.
func TestBackupNeverTouchesAFileThatIsNotReplaceable(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	stem := assembledStem(j)
	if err := os.MkdirAll(filepath.Dir(stem), 0o755); err != nil {
		t.Fatal(err)
	}
	orig := syncPath
	t.Cleanup(func() { syncPath = orig })
	syncPath = func(path string) error { // after every check, before the burst
		if err := os.WriteFile(stem+".vtt", []byte("MINE"), 0o600); err != nil {
			t.Error(err)
		}
		return orig(path)
	}
	origLink := linkFile
	t.Cleanup(func() { linkFile = origLink })
	linkFile = func(a, b string) error {
		if a == stem+".vtt" {
			t.Errorf("the user's file was linked to %s", filepath.Base(b))
		}
		return origLink(a, b)
	}
	if err := p.assemble(j); err == nil {
		t.Fatal("the publish replaced the user's file")
	}
	if raw, _ := os.ReadFile(stem + ".vtt"); string(raw) != "MINE" {
		t.Fatalf("the user's file: %q", raw)
	}
}

// publicMessage of the broken-set error is its sentence, with no hidden file
// name and no path.
func TestBrokenSetSentenceNamesNoTempFile(t *testing.T) {
	msg := publicMessage(fmt.Errorf("x: %w", errOutputsBroken), "/srv/u")
	if strings.Contains(msg, backupMark) || strings.Contains(msg, vproject.TempMark) || !strings.Contains(msg, "the previous version is kept beside the files") {
		t.Fatalf("%q", msg)
	}
}
