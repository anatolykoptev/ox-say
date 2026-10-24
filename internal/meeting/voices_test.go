package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// diarFake answers like ox-diar for the far side groupFixture makes: 40 words from 1.0 s to 16.6 s at
// 0.4 s apiece, split in three voices (or two) of 100 s each (the figures only have to pass the product
// rule). calls counts the runs.
type diarFake struct {
	calls atomic.Int32
	err   error
	raw   []byte // answered as is, instead of the voices
	two   bool
	hold  func(ctx context.Context) error
	pcm   string // the file the last run was asked about
}

// voiceprint is a value only a fake embedding holds: if it shows up in a file, an embedding was written there.
const voiceprint = "0.31415927"

func (d *diarFake) run(ctx context.Context, pcm string) ([]byte, error) {
	d.calls.Add(1)
	d.pcm = pcm
	// the daemon's side of the contract: the answer, voiceprints in it, is a file in work/ for the length of the call
	work := filepath.Join(filepath.Dir(pcm), WorkDir)
	if err := os.MkdirAll(work, 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(work, DiarizationJSON), []byte(`{"embedding":[`+voiceprint+`]}`), 0o600); err != nil {
		return nil, err
	}
	if d.hold != nil {
		if err := d.hold(ctx); err != nil {
			return nil, err
		}
	}
	if d.err != nil {
		return nil, d.err
	}
	if d.raw != nil {
		return d.raw, nil
	}
	vp := []float32{0.31415927, 0.5, 0.25}
	out := Diarization{Version: DiarizationVersion, DurationS: 30,
		Speakers: []DiarSpeaker{{ID: 0, SpeechS: 100, Embedding: vp}, {ID: 1, SpeechS: 100, Embedding: vp}, {ID: 2, SpeechS: 100, Embedding: vp}},
		Segments: []DiarSegment{{S: 0.9, E: 6.4, Spk: 0}, {S: 6.4, E: 11.8, Spk: 1}, {S: 11.8, E: 17, Spk: 2}}}
	if d.two {
		out.Speakers = out.Speakers[:2]
		out.Segments = []DiarSegment{{S: 0.9, E: 9, Spk: 0}, {S: 9, E: 17, Spk: 1}}
	}
	return json.Marshal(out)
}

func groupFixture(t *testing.T, d *diarFake) *fixture {
	t.Helper()
	f := newFixture(t)
	f.r.Diarize = d.run
	inner := f.r.Transcribe
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if strings.HasPrefix(filepath.Base(wav), "them-") {
			f.calls.Add(1)
			return &stt.Result{Words: words(1, strings.Repeat("alpha bravo charlie delta echo foxtrot golf hotel ", 5))}, nil
		}
		return inner(ctx, wav)
	}
	return f
}

func readFile(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	return string(b)
}

// Three voices on the far side: the transcript names them, the manifest says how many and in which
// mode, the diarizer's answer is not kept, and the notes are told there are separate people.
// Mutation: internal/meeting/runner.go transcribe, replace `turns = SplitByVoice(turns, vr.of)` with `_ = vr` ->
// RED (one far-side label).
func TestAGroupCallGetsItsVoices(t *testing.T) {
	d := &diarFake{}
	f := groupFixture(t, d)
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	m := f.load(t, id)
	dir, _ := f.r.Store.Dir(id)
	if m.Status != StatusDone || m.VoiceMode != VoicesAuto || m.Voices != 3 {
		t.Fatalf("manifest = %+v", m)
	}
	tr := readFile(t, dir, TranscriptMD)
	for _, want := range []string{"**Anatoly**", "**Speaker 1**", "**Speaker 2**", "**Speaker 3**"} {
		if !strings.Contains(tr, want) {
			t.Errorf("transcript lacks %q:\n%s", want, tr)
		}
	}
	if strings.Contains(tr, "**Other**") {
		t.Errorf("the far side kept its single label:\n%s", tr)
	}
	if want := filepath.Join(dir, ThemPCM); d.pcm != want {
		t.Errorf("the diarizer was asked about %q, want the far side's channel %q", d.pcm, want)
	}
	if m.DiarReason != "" || contains(m.Warnings, WarnNoDiarization) || contains(m.Warnings, WarnDiarUnavailable) {
		t.Errorf("a working diarization left a problem: %+v", m)
	}
	chat := f.r.Chat.(*fakeChat)
	if len(chat.reqs) == 0 || !strings.Contains(chat.reqs[0].System, `"Speaker 1", "Speaker 2", "Speaker 3"`) {
		t.Errorf("the notes prompt does not name the voices: %+v", chat.reqs)
	}
}

// A diarizer that breaks costs the voices, never the meeting, and the meeting says how it broke.
// Mutation: internal/meeting/voices.go, replace `return voiceResult{warn: WarnNoDiarization, reason: reason}, nil`
// with `return voiceResult{}, err` -> RED (the meeting fails); change `reason = DiarBadOutput` to
// `reason = DiarEngineError` -> RED (the bad_output case).
func TestADiarizerFailureLeavesOneLabelAndAWarningWithItsReason(t *testing.T) {
	for name, tc := range map[string]struct {
		d      *diarFake
		warn   string
		reason string
	}{
		"exit status":          {&diarFake{err: errors.New("ox-diar exited 1")}, WarnNoDiarization, DiarEngineError},
		"timeout":              {&diarFake{err: fmt.Errorf("ox-diar: %w", context.DeadlineExceeded)}, WarnNoDiarization, DiarTimeout},
		"unreadable json":      {&diarFake{raw: []byte(`{"version":9}`)}, WarnNoDiarization, DiarBadOutput},
		"engine refused":       {&diarFake{err: &DiarUnavailableError{Reason: DiarOSTooOld}}, WarnDiarUnavailable, DiarOSTooOld},
		"models will not load": {&diarFake{err: &DiarUnavailableError{Reason: DiarModelsUnusable, Detail: "cannot load"}}, WarnDiarUnavailable, DiarModelsUnusable},
	} {
		f := groupFixture(t, tc.d)
		id := f.start(t, 30, 30, 5000, false)
		if err := f.r.Process(context.Background(), id); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		m := f.load(t, id)
		dir, _ := f.r.Store.Dir(id)
		if m.Status != StatusDone || m.VoiceMode != "" || !contains(m.Warnings, tc.warn) || m.DiarReason != tc.reason {
			t.Errorf("%s: manifest = %+v", name, m)
		}
		if tc.warn == WarnDiarUnavailable && contains(m.Warnings, WarnNoDiarization) {
			t.Errorf("%s: a refusal was recorded as a failure: %v", name, m.Warnings)
		}
		if tr := readFile(t, dir, TranscriptMD); !strings.Contains(tr, "**Other**") || strings.Contains(tr, "Speaker 1") {
			t.Errorf("%s: transcript:\n%s", name, tr)
		}
	}
}

// A Mac that cannot run the diarizer is told so before anything starts: the diarizer is not called, the
// meeting carries WarnDiarUnavailable and the reason, and it is no failure.
// Mutation: internal/meeting/voices.go, delete the `r.DiarizeReady != nil` block -> RED (the diarizer runs).
func TestAnUnavailableDiarizerIsNotStartedAndIsNotAFailure(t *testing.T) {
	for _, code := range []string{DiarOSTooOld, DiarCPUUnsupported, DiarEngineMissing, DiarModelsMissing, DiarModelsUnusable} {
		d := &diarFake{}
		f := groupFixture(t, d)
		f.r.DiarizeReady = func() string { return code }
		id := f.start(t, 30, 30, 5000, false)
		if err := f.r.Process(context.Background(), id); err != nil {
			t.Fatal(err)
		}
		m := f.load(t, id)
		if d.calls.Load() != 0 || m.Status != StatusDone || !contains(m.Warnings, WarnDiarUnavailable) ||
			contains(m.Warnings, WarnNoDiarization) || m.DiarReason != code || m.VoiceMode != "" {
			t.Errorf("%s: the diarizer ran %d times, manifest = %+v", code, d.calls.Load(), m)
		}
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// A daemon shutdown during diarization leaves the meeting where it was.
// Mutation: internal/meeting/voices.go, delete `if ctx.Err() != nil { return voiceResult{}, ctx.Err() }` -> RED
// (the shutdown is recorded as a diarization failure and the meeting finishes without voices).
func TestShutdownDuringDiarizationLeavesTheMeetingResumable(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	d := &diarFake{hold: func(ctx context.Context) error { cancel(); return ctx.Err() }}
	f := groupFixture(t, d)
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(ctx, id); err == nil {
		t.Fatal("Process returned nil after the shutdown")
	}
	if st := f.load(t, id).Status; st != StatusTranscribing {
		t.Fatalf("status = %s", st)
	}
}

// RetryVoices tries the voices again when the diarizer broke and the far side's audio is still here (M5). The
// pieces of the first pass are gone, so it is a transcription again; the next pass has the voices.
// Mutation: internal/meeting/runner.go RetryVoices, change `if !wantsVoicesAgain(dir, m) {` to `if false {` -> RED
// (the refusal tests); delete the `r.Enqueue(id)` line -> RED (the meeting waits for nobody).
func TestRetryVoicesTriesTheVoicesAgainAfterAFailure(t *testing.T) {
	d := &diarFake{err: errors.New("ox-diar exited 1")}
	f := groupFixture(t, d)
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); !contains(m.Warnings, WarnNoDiarization) || m.VoiceMode != "" {
		t.Fatalf("setup: %+v", m)
	}
	d.err = nil
	f.r.mu.Lock() // the queue the first pass left, as if the runner had taken the meeting off it
	f.r.pending, f.r.order = map[string]bool{}, nil
	f.r.mu.Unlock()
	m, err := f.r.RetryVoices(id)
	if err != nil || m.Status != StatusQueued {
		t.Fatalf("RetryVoices = %+v, %v; want the meeting queued for the transcript", m, err)
	}
	if f.r.Active() != 1 {
		t.Fatalf("the retried meeting is not on the runner's queue (%d active)", f.r.Active())
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	got := f.load(t, id)
	dir, _ := f.r.Store.Dir(id)
	if got.Status != StatusDone || got.VoiceMode != VoicesAuto || got.Voices != 3 || got.DiarReason != "" || contains(got.Warnings, WarnNoDiarization) {
		t.Fatalf("after the retry: %+v", got)
	}
	if tr := readFile(t, dir, TranscriptMD); !strings.Contains(tr, "**Speaker 3**") {
		t.Errorf("transcript:\n%s", tr)
	}
}

// Only a failure, and only with the audio: anything else is refused and the meeting is left as it was. And Retry,
// which the app calls by itself (at launch, for a meeting waiting on the notes model), never transcribes again
// because of a failed diarization: it writes the notes.
// Mutations: internal/meeting/runner.go wantsVoicesAgain, change `!slices.Contains(m.Warnings, WarnNoDiarization)` to
// `slices.Contains(m.Warnings, "zzz")` -> RED (an unavailable diarizer is retried); in resumeStatus return
// `StatusQueued` for a meeting that wantsVoicesAgain -> RED (Retry transcribes again).
func TestRetryVoicesRefusesWhatHasNothingToRetry(t *testing.T) {
	refused := func(f *fixture, id string) {
		t.Helper()
		before := f.load(t, id)
		if _, err := f.r.RetryVoices(id); err == nil {
			t.Errorf("RetryVoices accepted a meeting with nothing to retry: %+v", before)
		}
		if got := f.load(t, id); got.Status != before.Status {
			t.Errorf("a refused retry moved the meeting: %s -> %s", before.Status, got.Status)
		}
	}
	// a Mac that cannot do it: nothing broke, retrying cannot help
	f := groupFixture(t, &diarFake{})
	f.r.DiarizeReady = func() string { return DiarOSTooOld }
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	refused(f, id)
	// voices that worked
	f = groupFixture(t, &diarFake{})
	id = f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	refused(f, id)
	// a failure whose far-side audio is gone
	d := &diarFake{err: errors.New("boom")}
	f = groupFixture(t, d)
	id = f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if err := os.Remove(filepath.Join(dir, ThemPCM)); err != nil {
		t.Fatal(err)
	}
	refused(f, id)
	// with the audio back, Retry still only writes the notes, and so does the automatic retry of a failed meeting
	writePCM(t, dir, ThemPCM, 30, 5000)
	calls := d.calls.Load()
	if m, err := f.r.Retry(id); err != nil || m.Status != StatusSummarizing {
		t.Fatalf("Retry = %+v, %v; want the notes only", m, err)
	}
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusFailed }); err != nil {
		t.Fatal(err)
	}
	f.r.Recover()
	if got := f.load(t, id).Status; got != StatusSummarizing {
		t.Errorf("an automatic retry resumes at %s", got)
	}
	if d.calls.Load() != calls {
		t.Errorf("the diarizer ran again without anyone asking")
	}
}

// A new diarization numbers the voices again, so the names and merges of the old one are dropped; the name given
// to the single far-side label is about the person, not the numbering, and stays.
// Mutation: internal/meeting/voices.go dropVoiceState, replace the body's `return SaveSpeakers(dir, keep)` with
// `return nil` -> RED (the old voice names survive).
func TestANewDiarizationKeepsOnlyTheFarSideName(t *testing.T) {
	d := &diarFake{}
	f := groupFixture(t, d)
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	old := SpeakerState{Names: map[string]string{SpeakerThem: "Maria", "them:1": "Ivan"}, Merge: map[string]string{"them:3": "them:1"}, Split: true}
	if err := SaveSpeakers(dir, old); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	st, err := LoadSpeakers(dir)
	if err != nil || len(st.Names) != 1 || st.Names[SpeakerThem] != "Maria" || len(st.Merge) != 0 || st.Split {
		t.Fatalf("speakers.json after a new diarization = %+v, %v", st, err)
	}
}

// Two voices: one label until the user splits, then the voices, and the notes are written again.
func TestTheSplitOfferIsPrecomputedAndOneEditAway(t *testing.T) {
	d := &diarFake{two: true}
	f := groupFixture(t, d)
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if m := f.load(t, id); m.VoiceMode != VoicesOffer || m.Voices != 2 {
		t.Fatalf("manifest = %+v", m)
	}
	if tr := readFile(t, dir, TranscriptMD); !strings.Contains(tr, "**Other**") || strings.Contains(tr, "Speaker 1") {
		t.Fatalf("before the split:\n%s", tr)
	}
	yes := true
	v, err := f.r.EditSpeakers(id, Edit{Split: &yes, Rename: map[string]string{"them:2": "Olga"}})
	if err != nil {
		t.Fatal(err)
	}
	if !v.Split || len(v.Speakers) != 2 || v.Speakers[1].Label != "Olga" {
		t.Fatalf("view = %+v", v)
	}
	if tr := readFile(t, dir, TranscriptMD); !strings.Contains(tr, "**Speaker 1**") || !strings.Contains(tr, "**Olga**") {
		t.Errorf("after the split:\n%s", tr)
	}
	if st := f.load(t, id).Status; st != StatusSummarizing {
		t.Fatalf("status = %s, want the notes queued", st)
	}
	chat := f.r.Chat.(*fakeChat)
	before := len(chat.reqs)
	chat.replies = append(chat.replies, chat.replies...)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if len(chat.reqs) == before || !strings.Contains(chat.reqs[before].System, `"Speaker 1", "Olga"`) {
		t.Errorf("the notes were not written again with the names: %d -> %d", before, len(chat.reqs))
	}
	// the same edit again changes nothing and does not queue the notes
	if _, err := f.r.EditSpeakers(id, Edit{Split: &yes}); err != nil || f.load(t, id).Status != StatusDone {
		t.Errorf("a repeated edit: %v, status %s", err, f.load(t, id).Status)
	}
}

func TestSpeakersCannotBeEditedWhileTheMeetingIsBeingProcessed(t *testing.T) {
	f := groupFixture(t, &diarFake{})
	id := f.start(t, 30, 30, 5000, false)
	yes := true
	if _, err := f.r.EditSpeakers(id, Edit{Split: &yes}); !errors.Is(err, ErrSpeakersBusy) {
		t.Fatalf("err = %v", err)
	}
	if _, err := f.r.Speakers(id); !errors.Is(err, ErrSpeakersBusy) {
		t.Fatalf("a transcript still to come: err = %v", err)
	}
}

// M4: the speakers' embeddings are voiceprints of people who never agreed to one. After a meeting is processed no
// file in its directory holds one.
// Mutation: internal/meeting/voices.go, after `d, err = ParseDiarization(raw)` add
// `_ = os.WriteFile(filepath.Join(dir, DiarizationJSON), raw, 0o600)` -> RED.
func TestNoVoiceprintReachesTheMeetingDirectory(t *testing.T) {
	f := groupFixture(t, &diarFake{})
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Voices != 3 {
		t.Fatalf("setup: no voices: %+v", m)
	}
	dir, _ := f.r.Store.Dir(id)
	err := filepath.WalkDir(dir, func(path string, e os.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return err
		}
		b, rerr := os.ReadFile(path)
		if rerr != nil {
			return rerr
		}
		if strings.Contains(string(b), voiceprint) {
			t.Errorf("%s holds an embedding", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// What a crash can leave behind, a voiceprint in work/, goes with the audio when retention runs; the transcript
// keeps its voices, so the names and the split keep working.
// Mutation: internal/meeting/retention.go deleteAudio, delete the `os.RemoveAll(filepath.Join(dir, WorkDir))` call -> RED.
func TestRetentionDeletesAStrayVoiceprintWithTheAudio(t *testing.T) {
	f := groupFixture(t, &diarFake{})
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	stray := filepath.Join(dir, WorkDir, DiarizationJSON)
	if err := os.MkdirAll(filepath.Dir(stray), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stray, []byte(`{"embedding":[`+voiceprint+`]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	f.now = f.now.Add(40 * 24 * time.Hour)
	if n := f.r.SweepRetention(); n != 1 {
		t.Fatalf("swept %d meetings, want 1", n)
	}
	if _, err := os.Stat(stray); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("work/diarization.json survived the sweep: %v", err)
	}
	for _, kept := range []string{TranscriptJSON, TranscriptMD, NotesMD} {
		if _, err := os.Stat(filepath.Join(dir, kept)); err != nil {
			t.Errorf("%s was deleted: %v", kept, err)
		}
	}
	if v, err := f.r.Speakers(id); err != nil || len(v.Speakers) != 3 {
		t.Errorf("the voices after the sweep: %+v %v", v, err)
	}
}

func voiceprintLeft(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, WorkDir, DiarizationJSON))
	return err == nil
}

// The diarizer's answer file holds voiceprints; it is removed the moment the answer has been read, whatever
// became of the run: read and used, an error, an unreadable answer, a refusal, a daemon shutdown, a run a later
// Finish superseded. (Runs that finish the transcript also remove work/ whole; the cases that do not are the ones
// that matter, and voices() is called directly so the rest are measured at the point of the removal.)
// Mutation: internal/meeting/voices.go, delete the `defer r.dropVoiceprints(dir)` line -> RED (every case).
func TestTheVoiceprintFileIsGoneWhenTheRunEnds(t *testing.T) {
	ws := words(1, strings.Repeat("alpha bravo charlie delta echo foxtrot golf hotel ", 5))
	for name, d := range map[string]*diarFake{
		"read and used": {},
		"engine error":  {err: errors.New("ox-diar exited 1")},
		"bad output":    {raw: []byte(`{"version":9}`)},
		"refusal":       {err: &DiarUnavailableError{Reason: DiarOSTooOld}},
		"timeout":       {err: context.DeadlineExceeded},
	} {
		f := groupFixture(t, d)
		_, dir, err := f.r.Store.Create(Manifest{Labels: Labels{Me: "Anatoly", Them: "Other"}}, t0)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.r.voices(context.Background(), dir, ws); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if d.calls.Load() != 1 {
			t.Fatalf("%s: the diarizer ran %d times", name, d.calls.Load())
		}
		if voiceprintLeft(dir) {
			t.Errorf("%s: work/%s is still there after the run", name, DiarizationJSON)
		}
	}
	// a shutdown in the middle of the run
	ctx, cancel := context.WithCancel(context.Background())
	d := &diarFake{hold: func(ctx context.Context) error { cancel(); return ctx.Err() }}
	f := groupFixture(t, d)
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	if err := f.r.Process(ctx, id); err == nil {
		t.Fatal("Process returned nil after the shutdown")
	}
	if voiceprintLeft(dir) {
		t.Errorf("shutdown: work/%s is still there", DiarizationJSON)
	}
	// a run a later Finish superseded: the meeting is queued again while the diarizer works
	var id2 string
	var f2 *fixture
	d2 := &diarFake{hold: func(context.Context) error {
		_, err := f2.r.Store.Update(id2, func(m *Manifest) { m.Status = StatusQueued })
		return err
	}}
	f2 = groupFixture(t, d2)
	id2 = f2.start(t, 30, 30, 5000, false)
	dir2, _ := f2.r.Store.Dir(id2)
	if err := f2.r.Process(context.Background(), id2); err != nil {
		t.Fatal(err)
	}
	if st := f2.load(t, id2).Status; st != StatusQueued {
		t.Fatalf("the superseded run moved the meeting to %s", st)
	}
	if voiceprintLeft(dir2) {
		t.Errorf("superseded: work/%s is still there", DiarizationJSON)
	}
}

// settledGroup is a processed group call, three voices, notes written.
func settledGroup(t *testing.T) (*fixture, string, string) {
	t.Helper()
	f := groupFixture(t, &diarFake{})
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	return f, id, dir
}

// A merge saves the speakers marked "notes stale", queues the notes, and the mark goes when notes are written. The
// same request again, after the first died with the speakers saved and the notes not queued, queues them.
// Mutations: internal/meeting/speakers_runner.go EditSpeakers, delete the `if cur.NotesStale {` block -> RED
// (the repeat does nothing); internal/meeting/runner.go writeNotes, delete `clearNotesStale(dir)` -> RED (the mark
// outlives the notes).
func TestAMergeThatDiedBeforeQueueingTheNotesIsFinishedByTheSameRequest(t *testing.T) {
	f, id, dir := settledGroup(t)
	merge := Edit{Merge: map[string]string{"them:3": "them:1"}}
	if _, err := f.r.EditSpeakers(id, merge); err != nil {
		t.Fatal(err)
	}
	st, _ := LoadSpeakers(dir)
	if !st.NotesStale || f.load(t, id).Status != StatusSummarizing {
		t.Fatalf("after a merge: stale %v, status %s", st.NotesStale, f.load(t, id).Status)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	st, _ = LoadSpeakers(dir)
	if st.NotesStale || f.load(t, id).Status != StatusDone {
		t.Fatalf("after the notes: stale %v, status %s", st.NotesStale, f.load(t, id).Status)
	}
	// the request again, with nothing to change: nothing happens
	if _, err := f.r.EditSpeakers(id, merge); err != nil || f.load(t, id).Status != StatusDone {
		t.Fatalf("a repeat of a finished edit: %v, status %s", err, f.load(t, id).Status)
	}
	// the first attempt died after saving the speakers: marked, never queued
	st.NotesStale = true
	if err := SaveSpeakers(dir, st); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.EditSpeakers(id, merge); err != nil {
		t.Fatal(err)
	}
	if got := f.load(t, id).Status; got != StatusSummarizing {
		t.Fatalf("the repeat did not queue the notes: status %s", got)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if st, _ = LoadSpeakers(dir); st.NotesStale {
		t.Error("the mark outlived the notes")
	}
}

// Two edits of one meeting at once do not lose each other's change: the read-modify-write is one at a time.
// The hook holds each edit after it has read the state until the other has read too (or 300 ms pass, which is
// what happens when the second is kept waiting).
// Mutation: internal/meeting/speakers_runner.go EditSpeakers, delete the `mu.(*sync.Mutex).Lock()` line -> RED
// (one of the names is lost).
func TestConcurrentSpeakerEditsDoNotLoseEachOther(t *testing.T) {
	f, id, dir := settledGroup(t)
	var arrived atomic.Int32
	both := make(chan struct{})
	f.r.afterSpeakersRead = func() {
		if arrived.Add(1) == 2 {
			close(both)
		}
		select {
		case <-both:
		case <-time.After(300 * time.Millisecond):
		}
	}
	errs := make(chan error, 2)
	for voice, name := range map[string]string{"them:1": "Ivan", "them:2": "Olga"} {
		go func() {
			_, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{voice: name}})
			errs <- err
		}()
	}
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	st, _ := LoadSpeakers(dir)
	if st.Names["them:1"] != "Ivan" || st.Names["them:2"] != "Olga" {
		t.Errorf("names after two edits at once = %v", st.Names)
	}
}
