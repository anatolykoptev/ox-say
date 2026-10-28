package daemon

import (
	"os"
	"path/filepath"
	"strings"
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
