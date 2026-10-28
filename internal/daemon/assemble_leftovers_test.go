package daemon

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// #154.2: the normalised audio is fsynced before it is renamed to its
// destination.
// Mutation: produce_assemble.go stageWAV, delete the syncPath call -> RED.
func TestPublishedWAVIsSyncedBeforeItsRename(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	var events []string
	origSync, origRename := syncPath, renameFile
	t.Cleanup(func() { syncPath, renameFile = origSync, origRename })
	syncPath = func(path string) error {
		events = append(events, "sync:"+filepath.Base(path))
		return origSync(path)
	}
	renameFile = func(from, to string) error {
		if strings.HasSuffix(from, normSuffix) {
			events = append(events, "rename:"+filepath.Base(from))
		}
		return origRename(from, to)
	}
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	var syncAt, renameAt = -1, -1
	for i, e := range events {
		switch {
		case strings.HasPrefix(e, "sync:") && strings.HasSuffix(e, normSuffix):
			syncAt = i
		case strings.HasPrefix(e, "rename:"):
			renameAt = i
		}
	}
	if syncAt < 0 || renameAt < 0 || syncAt > renameAt {
		t.Fatalf("event order %v: the normalised file must be synced before it is renamed", events)
	}
}

// #154.5: crash temps of this project's outputs are swept from the output
// directory when old; a fresh temp (a live publish), another name and a
// directory stay.
// Mutation: produce_assemble.go publish, delete the sweepOutputTemps call -> RED.
// Mutation: sweepOutputTemps, drop the age check -> the fresh temp goes -> RED.
func TestPublishSweepsStaleOutputTemps(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	stem := assembledStem(j)
	dir := filepath.Dir(stem)
	old := time.Now().Add(-time.Hour)
	mk := func(name string, mt time.Time) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, mt, mt); err != nil {
			t.Fatal(err)
		}
		return path
	}
	base := filepath.Base(stem)
	stale := []string{mk("."+base+".srt"+vproject.TempMark+"111", old), mk("."+base+".wav"+vproject.TempMark+"222", old)}
	fresh := mk("."+base+".vtt"+vproject.TempMark+"333", time.Now())
	other := mk(".other.srt"+vproject.TempMark+"444", old)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	for _, s := range stale {
		if _, err := os.Lstat(s); !os.IsNotExist(err) {
			t.Errorf("%s survived the sweep", filepath.Base(s))
		}
	}
	for _, keep := range []string{fresh, other} {
		if _, err := os.Lstat(keep); err != nil {
			t.Errorf("%s was removed: %v", filepath.Base(keep), err)
		}
	}
}

// #154.7: a take of another rate fails the assembly naming its chunk.
// Mutation: produce_assemble.go add, return the bare Write error -> RED.
func TestMixedRateErrorNamesTheChunk(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	writeTake(t, j.dir, j.m.Chunks[1].Pick, fixtureTake(24000), "Второе.")
	err := p.assemble(j)
	if err == nil || !strings.Contains(err.Error(), "chunk 1") {
		t.Errorf("error %v does not name chunk 1", err)
	}
}

// #154.3: a file that appears at an output name after the pre-check - here
// while the staged WAV is being synced, which happens after every check and
// before the burst - is never replaced. Whatever the burst had placed is
// removed, the user's file stays byte for byte, and no temp is left.
// Mutation: produce_assemble.go placeStaged, `linkFile(s.tmp, s.dest)` ->
// `renameFile(s.tmp, s.dest)` (the pre-check is all there is) -> the user's file
// is replaced -> RED. Mutation: removeOutputs, drop the `i >= k &&
// !replaceable` guard -> the user's file is deleted with the set -> RED.
func TestPublishNeverClobbersAFileThatAppearsMeanwhile(t *testing.T) {
	for _, ext := range outputExts {
		t.Run(ext, func(t *testing.T) {
			f := newFakePorts(t)
			p, j := assembleFixture(t, f)
			stem := assembledStem(j)
			if err := os.MkdirAll(filepath.Dir(stem), 0o755); err != nil {
				t.Fatal(err)
			}
			orig := syncPath
			t.Cleanup(func() { syncPath = orig })
			syncPath = func(path string) error {
				if err := os.WriteFile(stem+ext, []byte("MINE"), 0o600); err != nil {
					t.Error(err)
				}
				return orig(path)
			}
			err := p.assemble(j)
			if err == nil || !strings.Contains(err.Error(), "left alone") {
				t.Fatalf("assemble over a file that appeared meanwhile: %v", err)
			}
			if b, _ := os.ReadFile(stem + ext); string(b) != "MINE" {
				t.Errorf("%s was replaced: %q", ext, b)
			}
			for _, other := range outputExts {
				if other == ext {
					continue
				}
				if _, err := os.Lstat(stem + other); !os.IsNotExist(err) {
					t.Errorf("%s was left in a half-published set: %v", other, err)
				}
			}
			noTemps(t, filepath.Dir(stem))
		})
	}
}

// A volume without hard links cannot take the claim; the publish falls back
// to the rename rather than failing every assembly there.
// Mutation: produce_assemble.go placeStaged, the default branch `return
// renameFile(s.tmp, s.dest)` -> `return err` -> RED.
func TestPublishFallsBackToRenameWithoutHardLinks(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	orig := linkFile
	t.Cleanup(func() { linkFile = orig })
	linkFile = func(string, string) error { return syscall.ENOTSUP }
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	for _, ext := range outputExts {
		if _, err := os.Lstat(assembledStem(j) + ext); err != nil {
			t.Errorf("%s: %v", ext, err)
		}
	}
}

// A staged temp that cannot be unlinked after its link is a leftover, not a failed publish: the outputs
// are in place, a WARN names the temp without its directory, and the sweep reaps it once it is old.
// Mutation: produce_assemble.go placeStaged, return the removeFile error as err -> the publish fails -> RED.
// Mutation: publish, drop the `left != nil` Warn -> RED on the log. Mutation: sweepOutputTemps, skip
// every entry -> the old temp survives -> RED.
func TestUnlinkFailureAfterLinkIsWarnedAndSwept(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	var buf bytes.Buffer
	p.log = slog.New(slog.NewTextHandler(&buf, nil))
	orig := removeFile
	t.Cleanup(func() { removeFile = orig })
	removeFile = func(path string) error {
		if strings.Contains(filepath.Base(path), vproject.TempMark) {
			return &os.PathError{Op: "remove", Path: path, Err: syscall.EACCES}
		}
		return orig(path)
	}
	if err := p.assemble(j); err != nil {
		t.Fatalf("a failed temp unlink failed the publish: %v", err)
	}
	stem := assembledStem(j)
	for _, ext := range outputExts {
		if _, err := os.Lstat(stem + ext); err != nil {
			t.Errorf("%s: %v", ext, err)
		}
	}
	log := buf.String()
	if !strings.Contains(log, "level=WARN") || !strings.Contains(log, "staged temp") || strings.Contains(log, filepath.Dir(stem)) {
		t.Errorf("want a WARN naming the temp without its directory: %q", log)
	}
	dir := filepath.Dir(stem)
	var temps []string
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), vproject.TempMark) {
			temps = append(temps, filepath.Join(dir, e.Name()))
		}
	}
	if len(temps) == 0 {
		t.Fatal("no leftover temp: the failing unlink was not reached")
	}
	old := time.Now().Add(-2 * time.Hour)
	for _, tp := range temps {
		if err := os.Chtimes(tp, old, old); err != nil {
			t.Fatal(err)
		}
	}
	sweepOutputTemps(stem, tempSweepMinAge)
	noTemps(t, dir)
}
