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
// fails too - the survivor stays under its backup name and the project must
// not read done: its files are not all the ones its outputs describe. Here the
// burst fails at .words.json and the restore of .srt fails. The person reads
// one plain sentence with no hidden file name in it.
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
	srt, words := stem+".srt", stem+".words.json"
	failRenames(t, func(from, to string) bool {
		return to == words || (to == srt && strings.Contains(filepath.Base(from), backupMark))
	}, errors.New("read-only volume"))

	if _, err := p.delivery(s.ID, nil, ptr(-18.0)); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)

	m = manifestOf(t, f, s.ID)
	if m.Status != vproject.StatusFailed {
		t.Fatalf("status %q error %q: a set that is not all there must not read done", m.Status, m.Error)
	}
	if m.Error != errOutputsBroken.Error() || strings.Contains(m.Error, backupMark) || strings.Contains(m.Error, vproject.TempMark) {
		t.Fatalf("error %q", m.Error)
	}
	if m.Settings.LUFS != lufs0 || m.Outputs != outputs0 {
		t.Fatalf("lufs %v, outputs %+v", m.Settings.LUFS, m.Outputs)
	}
	var holdsOld bool
	entries, _ := os.ReadDir(filepath.Dir(stem))
	for _, e := range entries {
		if strings.Contains(e.Name(), backupMark) {
			if raw, _ := os.ReadFile(filepath.Join(filepath.Dir(stem), e.Name())); string(raw) == before[".srt"] {
				holdsOld = true
			}
		}
	}
	if !holdsOld {
		t.Fatal("no backup holds the old .srt")
	}
	for _, e := range []string{".vtt", ".words.json", ".manifest.json", ".wav"} {
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
// Mutation: produce_ops.go deliver, drop `j.m.PendingLUFS, j.m.PendingStatus =
// lufs, j.prevStatus` -> the manifest carries nothing -> RED. Mutation:
// produce_ops.go deliver, record only PendingLUFS -> the status is empty -> RED.
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
	if m.PendingLUFS == nil || *m.PendingLUFS != -18.0 || m.PendingStatus != vproject.StatusDone {
		t.Fatalf("the pending loudness and the status it had are not on disk: %v %q", m.PendingLUFS, m.PendingStatus)
	}
	waitTerminal(t, p, s.ID)
	m = manifestOf(t, f, s.ID)
	if m.PendingLUFS != nil || m.PendingStatus != "" || m.Settings.LUFS != -18.0 || m.Status != vproject.StatusDone {
		t.Fatalf("after the run: pending %v %q lufs %v status %q", m.PendingLUFS, m.PendingStatus, m.Settings.LUFS, m.Status)
	}
}

// A crash mid loudness-only run leaves "running" on disk with the pending
// target and the status the project had recorded: after the restart the
// project reads that status again, and its error says the change MAY not have
// applied (the publish could have finished an instant before the stop). The
// resume still re-assembles at the old target - that is understood - ends done
// and carries neither value on.
// Mutation: produce_ops.go manifest, drop the PendingStatus mapping -> the
// project reads interrupted -> RED. Mutation: produce_ops.go manifest, drop the
// PendingLUFS mapping -> error empty -> RED. Mutation: produce.go launch, drop
// the clearing of a stale pending value -> the resume still carries it -> RED.
func TestLoudnessOnlyCrashReadsThePreviousStatusWithMaybeDropped(t *testing.T) {
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
	m.Status, m.PendingLUFS, m.PendingStatus = vproject.StatusRunning, ptr(-18.0), vproject.StatusDone
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
	if st.Status != vproject.StatusDone {
		t.Fatalf("a crashed loudness-only run reads %q, want the %q it had", st.Status, vproject.StatusDone)
	}
	if !strings.Contains(st.Error, "may not have applied") || !strings.Contains(st.Error, "-18") {
		t.Fatalf("the maybe-dropped change is not reported: error %q", st.Error)
	}
	if st.Outputs != outputs0 {
		t.Fatalf("outputs %+v", st.Outputs)
	}

	var seenOnDisk *float64
	f.normHook = func() { // the resume's own launch has been saved by now
		if lm, lerr := vproject.Load(dir); lerr == nil {
			seenOnDisk = lm.PendingLUFS
		}
	}
	if _, err := p2.resume(s.ID, false); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p2, s.ID)
	if seenOnDisk != nil {
		t.Fatalf("the resume's launch kept the stale pending loudness %v on disk", *seenOnDisk)
	}
	m = manifestOf(t, f, s.ID)
	if m.Status != vproject.StatusDone || m.Error != "" || m.Settings.LUFS != lufs0 || m.PendingStatus != "" {
		t.Fatalf("after the resume: status %q error %q lufs %v pending %q", m.Status, m.Error, m.Settings.LUFS, m.PendingStatus)
	}
	if got := f.normTargets[len(f.normTargets)-1]; got != lufs0 {
		t.Fatalf("the resume re-assembled at %v LUFS, want the old %v", got, lufs0)
	}
}

// A pending marker with no usable status reads interrupted, and a pending
// loudness outside the range loudness accepts is ignored on load - it is
// neither reported nor kept.
// Mutation: produce_ops.go loadProject, drop the validLUFS check -> the
// out-of-range value is reported as a dropped change -> RED. Mutation:
// produce_ops.go settledStatus, return true -> a hand-edited status "running"
// is shown -> RED.
func TestPendingMarkerWithBadValuesIsIgnored(t *testing.T) {
	for name, c := range map[string]struct {
		lufs   float64
		status string
		want   string
		err    bool
	}{
		"no status recorded":    {-18, "", vproject.StatusInterrupted, true},
		"a transient status":    {-18, vproject.StatusRunning, vproject.StatusInterrupted, true},
		"out-of-range loudness": {-99, vproject.StatusDone, vproject.StatusInterrupted, false},
		"loudness above range":  {3, vproject.StatusDone, vproject.StatusInterrupted, false},
	} {
		t.Run(name, func(t *testing.T) {
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
			m.Status, m.PendingLUFS, m.PendingStatus = vproject.StatusRunning, ptr(c.lufs), c.status
			if err := m.Save(dir); err != nil {
				t.Fatal(err)
			}
			p2 := newProducer(f)
			p2.start()
			t.Cleanup(func() { p2.shutdown() })
			st, err := p2.status(s.ID)
			if err != nil {
				t.Fatal(err)
			}
			if st.Status != c.want || (st.Error != "") != c.err {
				t.Fatalf("status %q error %q", st.Status, st.Error)
			}
		})
	}
}
