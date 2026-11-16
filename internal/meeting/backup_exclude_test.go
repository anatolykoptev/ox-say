package meeting

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// Only audio leaves the backup (the files retention deletes, retiredNames): the work directory is marked when it is
// made, and nothing else is. The transcript, notes and manifest stay in the user's own backup.
func recordExcluded(t *testing.T) *[]string {
	t.Helper()
	var marked []string
	prev := excludeBackup
	excludeBackup = func(p string) error { marked = append(marked, p); return nil }
	t.Cleanup(func() { excludeBackup = prev })
	return &marked
}

// MakeWorkDir marks the directory it makes, and only that.
// Mutation: backup_exclude.go MakeWorkDir, delete the `excludeBackup(work)` call -> RED.
func TestMakeWorkDirMarksTheWorkDirectoryAndNothingElse(t *testing.T) {
	marked := recordExcluded(t)
	dir := t.TempDir()
	work, err := MakeWorkDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, WorkDir); work != want || len(*marked) != 1 || (*marked)[0] != want {
		t.Fatalf("work %q, marked %v, want exactly %q", work, *marked, want)
	}
	if st, err := os.Stat(work); err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("work dir = %v, %v; want mode 0700", st, err)
	}
}

// A mark that fails must not stop the transcription.
// Mutation: backup_exclude.go MakeWorkDir, `return "", err` in place of the logged warning -> RED.
func TestAFailedWorkDirMarkDoesNotRefuseTheDirectory(t *testing.T) {
	prev := excludeBackup
	excludeBackup = func(string) error { return errors.New("xattr not supported here") }
	t.Cleanup(func() { excludeBackup = prev })
	if _, err := MakeWorkDir(t.TempDir()); err != nil {
		t.Fatalf("MakeWorkDir refused the directory over a failed backup mark: %v", err)
	}
}

// The runner's call site: transcribing a meeting makes work/ through MakeWorkDir, so the mark is on the directory the
// clips are written to. A failing engine keeps work/ on disk. Neither the meetings root nor the meeting directory is
// marked: those hold the transcript and notes the user keeps.
// Mutation: runner.go transcribe, `work, err := MakeWorkDir(dir)` -> `work := filepath.Join(dir, WorkDir)` with an
// `os.MkdirAll(work, 0o700)` -> RED.
func TestTranscribingMarksTheWorkDirectoryExcluded(t *testing.T) {
	marked := recordExcluded(t)
	f := newFixture(t)
	f.sleeps()
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { return nil, errors.New("engine crashed") }
	id := f.start(t, 20, 0, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	_ = f.r.Process(context.Background(), id)
	if want := filepath.Join(dir, WorkDir); len(*marked) != 1 || (*marked)[0] != want {
		t.Fatalf("marked %v, want exactly %q", *marked, want)
	}
}

// The mark's bytes are what macOS writes itself (`tmutil addexclusion`): a binary plist with the string
// "com.apple.backupd". A different value is ignored by Time Machine without any error.
func TestBackupExcludeValueIsABinaryPlistOfBackupd(t *testing.T) {
	v := backupExcludeValue
	if string(v[:8]) != "bplist00" {
		t.Fatalf("header %q", v[:8])
	}
	if v[8] != 0x5f || v[9] != 0x10 || int(v[10]) != len("com.apple.backupd") {
		t.Fatalf("string marker % x", v[8:11])
	}
	if got := string(v[11 : 11+len("com.apple.backupd")]); got != "com.apple.backupd" {
		t.Fatalf("string %q", got)
	}
	if len(v) != 61 {
		t.Fatalf("length %d, want 61 (tmutil's)", len(v))
	}
}
