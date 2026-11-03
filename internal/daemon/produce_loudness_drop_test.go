package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// Issue #418: a loudness-only run must never cost a finished project its
// published file - a failed publish restores the previous set, a cut-short
// run says the change was dropped, and a publish that could not put the
// previous set back never reads as done.

// outputBytes reads every file the manifest's outputs name.
func outputBytes(t *testing.T, o vproject.Outputs) map[string]string {
	t.Helper()
	set := map[string]string{}
	for ext, p := range map[string]string{".wav": o.WAV, ".srt": o.SRT, ".vtt": o.VTT, ".words.json": o.Words, ".manifest.json": o.Manifest} {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("%s: %v", ext, err)
		}
		set[ext] = string(raw)
	}
	return set
}

// failRenamesOnce fails the first rename whose destination matches failTo -
// one failed place in the burst; the rollback's own renames still succeed.
func failRenamesOnce(t *testing.T, failTo func(to string) bool, err error) {
	t.Helper()
	orig := renameFile
	failed := false
	t.Cleanup(func() { renameFile = orig })
	renameFile = func(from, to string) error {
		if !failed && failTo(to) && strings.Contains(filepath.Base(from), vproject.TempMark) {
			failed = true
			return err
		}
		return orig(from, to)
	}
}

// A burst rename that fails - at the first, a middle or the last file of the
// set - leaves the whole previous set in place: every old file keeps its
// bytes under its published name, no temp is left, and the loudness-only
// delivery keeps the status, the outputs and the loudness target it had.
// Mutation: produce_assemble.go publish, drop the undoBurst call -> the old
// set is destroyed -> RED.
func TestLoudnessOnlyBurstFailureKeepsTheOldSet(t *testing.T) {
	for _, ext := range outputExts {
		t.Run(ext, func(t *testing.T) {
			f := newFakePorts(t)
			p := startedProducer(t, f)
			s, err := p.create(reelInput(t))
			if err != nil {
				t.Fatal(err)
			}
			waitTerminal(t, p, s.ID)
			m := manifestOf(t, f, s.ID)
			if m.Status != vproject.StatusDone {
				t.Fatalf("setup: status %q", m.Status)
			}
			lufs0, outputs0 := m.Settings.LUFS, m.Outputs
			before := outputBytes(t, outputs0)
			stem := strings.TrimSuffix(m.Settings.OutPath, ".wav")
			failRenamesOnce(t, func(to string) bool { return to == stem+ext }, errors.New("disk on fire"))

			if _, err := p.delivery(s.ID, nil, ptr(-18.0)); err != nil {
				t.Fatal(err)
			}
			waitTerminal(t, p, s.ID)

			m = manifestOf(t, f, s.ID)
			if m.Status != vproject.StatusDone || !strings.Contains(m.Error, "previous files were kept") {
				t.Fatalf("status %q error %q", m.Status, m.Error)
			}
			if m.Settings.LUFS != lufs0 || m.Outputs != outputs0 {
				t.Fatalf("lufs %v (want %v), outputs %+v (want %+v)", m.Settings.LUFS, lufs0, m.Outputs, outputs0)
			}
			for e, was := range outputBytes(t, outputs0) {
				if was != before[e] {
					t.Errorf("%s changed although the publish failed", e)
				}
			}
			noTemps(t, filepath.Dir(stem))
		})
	}
}

// When the rollback itself cannot put an old file back - its restore rename
// fails too - the survivor stays under its temp name and the project must not
// read done: outputs names a file that is not there. Here every rename to
// .words.json fails: the publish AND the restore.
// Mutation: produce.go outcome, drop the errOutputsBroken case -> status done -> RED.
func TestLoudnessOnlyBurstFailureUnrestoredIsFailed(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	m := manifestOf(t, f, s.ID)
	lufs0, outputs0 := m.Settings.LUFS, m.Outputs
	before := outputBytes(t, outputs0)
	stem := strings.TrimSuffix(m.Settings.OutPath, ".wav")
	dest := stem + ".words.json"
	failRenames(t, func(from, to string) bool {
		return to == dest && strings.Contains(filepath.Base(from), vproject.TempMark)
	}, errors.New("read-only volume"))

	if _, err := p.delivery(s.ID, nil, ptr(-18.0)); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)

	m = manifestOf(t, f, s.ID)
	if m.Status != vproject.StatusFailed {
		t.Fatalf("status %q error %q: a set that is not all there must not read done", m.Status, m.Error)
	}
	if !strings.Contains(m.Error, ".words.json") || !strings.Contains(m.Error, "could not all be restored") {
		t.Fatalf("the unrestored file is not named: error %q", m.Error)
	}
	if m.Settings.LUFS != lufs0 || m.Outputs != outputs0 {
		t.Fatalf("lufs %v, outputs %+v", m.Settings.LUFS, m.Outputs)
	}
	if _, err := os.Lstat(dest); !os.IsNotExist(err) {
		t.Errorf(".words.json is there: %v", err)
	}
	entries, err := os.ReadDir(filepath.Dir(stem))
	if err != nil {
		t.Fatal(err)
	}
	var survivors []string
	for _, e := range entries {
		if strings.Contains(e.Name(), vproject.TempMark) {
			survivors = append(survivors, e.Name())
		}
	}
	if len(survivors) != 1 {
		t.Fatalf("surviving temps %v, want exactly the retreated .words.json", survivors)
	}
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(stem), survivors[0]))
	if err != nil || string(raw) != before[".words.json"] {
		t.Fatalf("the survivor does not hold the old .words.json: %v", err)
	}
	for _, e := range []string{".wav", ".srt", ".vtt", ".manifest.json"} {
		raw, err := os.ReadFile(stem + e)
		if err != nil || string(raw) != before[e] {
			t.Errorf("%s was not restored: %v", e, err)
		}
	}
}

// A daemon shutdown mid loudness-only run is not "interrupted" silence: the
// project keeps the status it had - its file and target are untouched - and
// the error says the loudness change did not apply.
// Mutation: produce.go outcome, drop the pendingLUFS branch of the
// p.ctx.Err() case -> interrupted with no error -> RED.
func TestLoudnessOnlyInterruptKeepsFinishedAndSaysDropped(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	m := manifestOf(t, f, s.ID)
	lufs0, outputs0 := m.Settings.LUFS, m.Outputs
	before := outputBytes(t, outputs0)
	f.normErr = errors.New("ffmpeg killed")
	f.normHook = func() { p.stop() } // the daemon goes down mid-normalisation

	if _, err := p.delivery(s.ID, nil, ptr(-18.0)); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)

	m = manifestOf(t, f, s.ID)
	if m.Status != vproject.StatusDone {
		t.Fatalf("status %q, want the %q it had", m.Status, vproject.StatusDone)
	}
	if !strings.Contains(m.Error, "loudness") || !strings.Contains(m.Error, "-18") {
		t.Fatalf("the dropped change is not on the project: error %q", m.Error)
	}
	if m.Settings.LUFS != lufs0 || m.Outputs != outputs0 {
		t.Fatalf("lufs %v, outputs %+v", m.Settings.LUFS, m.Outputs)
	}
	for e, was := range outputBytes(t, outputs0) {
		if was != before[e] {
			t.Errorf("%s changed although the run was interrupted", e)
		}
	}
}

// A loudness-only launch persists the pending target on the manifest - the
// record a daemon that never comes back needs to say what did not apply -
// and the finished run carries none.
// Mutation: produce_ops.go deliver, drop `j.m.PendingLUFS = lufs` -> the
// manifest carries nothing -> RED.
func TestLoudnessOnlyDeliveryRecordsThePendingTarget(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	if _, err := p.delivery(s.ID, nil, ptr(-18.0)); err != nil {
		t.Fatal(err)
	}
	m, err := vproject.Load(filepath.Join(f.home, produceDir, s.ID)) // launch saved before delivery returned
	if err != nil {
		t.Fatal(err)
	}
	if m.PendingLUFS == nil || *m.PendingLUFS != -18.0 {
		t.Fatalf("the pending loudness is not on disk: %v", m.PendingLUFS)
	}
	waitTerminal(t, p, s.ID)
	m = manifestOf(t, f, s.ID)
	if m.PendingLUFS != nil || m.Settings.LUFS != -18.0 || m.Status != vproject.StatusDone {
		t.Fatalf("after the run: pending %v lufs %v status %q", m.PendingLUFS, m.Settings.LUFS, m.Status)
	}
}

// A crash mid loudness-only run leaves "running" on disk with the pending
// target recorded: after the restart the project reads interrupted and its
// error says which change was dropped. The resume still re-assembles at the
// old target - that is understood - and ends done.
// Mutation: produce_ops.go manifest, drop the PendingLUFS mapping -> error
// empty -> RED. Mutation: produce_ops.go deliver, drop `j.m.PendingLUFS =
// lufs` -> no pending marker -> RED.
func TestLoudnessOnlyCrashReadsInterruptedWithDroppedChange(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	dir := filepath.Join(f.home, produceDir, s.ID)
	m, err := vproject.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	lufs0, outputs0 := m.Settings.LUFS, m.Outputs
	m.Status, m.PendingLUFS = vproject.StatusRunning, ptr(-18.0)
	if err := m.Save(dir); err != nil {
		t.Fatal(err)
	}

	p2 := newProducer(f) // a fresh producer stands in for the daemon after the restart
	p2.start()
	t.Cleanup(func() { p2.shutdown() })
	st, err := p2.status(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Status != vproject.StatusInterrupted {
		t.Fatalf("a crashed loudness-only run reads %q", st.Status)
	}
	if !strings.Contains(st.Error, "loudness") || !strings.Contains(st.Error, "-18") {
		t.Fatalf("the dropped change is not reported: error %q", st.Error)
	}
	if st.Outputs != outputs0 {
		t.Fatalf("outputs %+v", st.Outputs)
	}

	if _, err := p2.resume(s.ID, false); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p2, s.ID)
	m = manifestOf(t, f, s.ID)
	if m.Status != vproject.StatusDone || m.Error != "" || m.Settings.LUFS != lufs0 {
		t.Fatalf("after the resume: status %q error %q lufs %v", m.Status, m.Error, m.Settings.LUFS)
	}
	if got := f.normTargets[len(f.normTargets)-1]; got != lufs0 {
		t.Fatalf("the resume re-assembled at %v LUFS, want the old %v", got, lufs0)
	}
}
