package meeting

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// writePCM writes sec seconds of tone (or zeros when tone is 0) as a channel file.
func writePCM(t *testing.T, dir, name string, sec int, tone int16) {
	t.Helper()
	b := make([]byte, sec*SampleRate*bytesPerSample)
	for i := 0; i < sec*SampleRate; i++ {
		binary.LittleEndian.PutUint16(b[i*2:], uint16(tone))
	}
	if err := os.WriteFile(filepath.Join(dir, name), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// fixture is a runner over fakes: the recognizer answers by channel (the wav
// name starts with "me-" or "them-"), the model answers valid notes.
type fixture struct {
	r     *Runner
	calls atomic.Int32
	now   time.Time
	notes string // NotesReady's answer
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{now: t0.Add(2 * time.Hour)}
	chat := &fakeChat{}
	for i := 0; i < 8; i++ {
		chat.replies = append(chat.replies, replyJSON(t, ChunkNotes{
			Summary:     "A short call.",
			ActionItems: []ActionItem{{Who: "Anatoly", What: "send the proposal", When: "Friday"}},
		}))
	}
	f.r = NewRunner(Deps{
		Store: newStore(t),
		Transcribe: func(_ context.Context, wav string) (*stt.Result, error) {
			f.calls.Add(1)
			text := "thanks everyone for joining today we will go through the plan and the open questions now"
			if strings.HasPrefix(filepath.Base(wav), "me-") {
				text = "happy to start with the status of the proposal and the budget for the next quarter"
			}
			return &stt.Result{Words: words(1, text)}, nil
		},
		Chat:       chat,
		NotesReady: func() string { return f.notes },
		Now:        func() time.Time { return f.now },
		Sleep:      func(time.Duration) {},
	})
	return f
}

// start makes a meeting with the given channel lengths and queues it.
func (f *fixture) start(t *testing.T, meSec, themSec int, tone int16, echo bool) string {
	t.Helper()
	m, dir, err := f.r.Store.Create(Manifest{Title: "Plan", Labels: Labels{Me: "Anatoly", Them: "Other"}, EchoRisk: echo}, t0)
	if err != nil {
		t.Fatal(err)
	}
	writePCM(t, dir, MePCM, meSec, tone)
	writePCM(t, dir, ThemPCM, themSec, tone)
	if _, err := f.r.Finish(m.ID, t0.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	return m.ID
}

func (f *fixture) load(t *testing.T, id string) *Manifest {
	t.Helper()
	m, err := f.r.Store.Load(id)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestProcessWritesTranscriptAndNotes(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	m := f.load(t, id)
	if m.Status != StatusDone || m.DurationS != 30 || m.Language != "en" {
		t.Fatalf("manifest = %+v", m)
	}
	dir, _ := f.r.Store.Dir(id)
	tr, _ := os.ReadFile(filepath.Join(dir, TranscriptMD))
	notes, _ := os.ReadFile(filepath.Join(dir, NotesMD))
	for _, want := range []string{"**Anatoly** [0:01]", "**Other** [0:01]"} {
		if !strings.Contains(string(tr), want) {
			t.Errorf("transcript lacks %q:\n%s", want, tr)
		}
	}
	if !strings.Contains(string(notes), "- [ ] Anatoly — send the proposal — Friday") {
		t.Errorf("notes lack the action item:\n%s", notes)
	}
}

// A second piece's words carry its offset: the transcript clock is the
// meeting's, not the piece's.
// Mutation: internal/meeting/runner.go recognize, delete `w.S += offset` ->
// RED (the second piece's words restart at 0:01).
func TestPiecesKeepTheMeetingClock(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 600, 0, 5000, false) // 600 s = three pieces
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	tr, _ := os.ReadFile(filepath.Join(dir, TranscriptMD))
	if !strings.Contains(string(tr), "[7:") { // a turn in the third piece (it starts near 7:30)
		t.Fatalf("no turn past 7:00 in the transcript:\n%s", tr)
	}
}

// A capture that heard nothing must not pass as a quiet meeting: the transcript
// is built, and the manifest carries the warning the app shows.
// Mutation: internal/meeting/runner.go transcribe, change `if !speech {` to
// `if speech {` -> RED (a silent system-audio tap goes unnoticed).
func TestSilentSystemAudioIsWarned(t *testing.T) {
	f := newFixture(t)
	m, dir, _ := f.r.Store.Create(Manifest{Labels: Labels{Me: "A", Them: "B"}}, t0)
	writePCM(t, dir, MePCM, 20, 5000)
	writePCM(t, dir, ThemPCM, 20, 0) // the tap recorded zeros
	_, _ = f.r.Finish(m.ID, t0.Add(time.Minute))
	if err := f.r.Process(context.Background(), m.ID); err != nil {
		t.Fatal(err)
	}
	got := f.load(t, m.ID)
	if len(got.Warnings) != 1 || got.Warnings[0] != WarnNoSystemAudio {
		t.Fatalf("warnings = %v, want [%s]", got.Warnings, WarnNoSystemAudio)
	}
	if f.calls.Load() != 1 { // only the mic channel reached the recognizer
		t.Fatalf("recognizer calls = %d, want 1: silence must not be transcribed", f.calls.Load())
	}
}

func TestMissingChannelFileIsTheSameWarning(t *testing.T) {
	f := newFixture(t)
	m, dir, _ := f.r.Store.Create(Manifest{}, t0)
	writePCM(t, dir, MePCM, 20, 5000) // no them.pcm at all
	_, _ = f.r.Finish(m.ID, t0.Add(time.Minute))
	_ = f.r.Process(context.Background(), m.ID)
	if got := f.load(t, m.ID); len(got.Warnings) != 1 || got.Warnings[0] != WarnNoSystemAudio || got.Status != StatusDone {
		t.Fatalf("manifest = %+v", got)
	}
}

// On speakers the echo is dropped from the transcript; on headphones the same
// words stay.
// Mutation: internal/meeting/runner.go transcribe, change `if m.EchoRisk` to
// `if false` -> RED (the speakers meeting keeps its echo).
func TestEchoGateAppliesOnlyWhenTheMeetingHadSpeakers(t *testing.T) {
	for _, tc := range []struct {
		echo     bool
		wantMine bool
	}{{true, false}, {false, true}} {
		f := newFixture(t)
		f.r.Transcribe = func(_ context.Context, wav string) (*stt.Result, error) {
			// both channels hear the same sentence, the mic a little later
			start := 1.0
			if strings.HasPrefix(filepath.Base(wav), "me-") {
				start = 1.3
			}
			return &stt.Result{Words: words(start, "so the plan is to ship the release on friday after the review")}, nil
		}
		id := f.start(t, 20, 20, 5000, tc.echo)
		_ = f.r.Process(context.Background(), id)
		dir, _ := f.r.Store.Dir(id)
		tr, _ := os.ReadFile(filepath.Join(dir, TranscriptMD))
		if got := strings.Contains(string(tr), "**Anatoly**"); got != tc.wantMine {
			t.Errorf("echo=%v: owner turn present = %v, want %v\n%s", tc.echo, got, tc.wantMine, tr)
		}
	}
}

// A dropped echo is not invisible: the manifest carries WarnEchoDropped and
// how many turns went, and the turns as they were BEFORE DropEcho stay on
// disk so a wrongly judged turn can be put back.
// Mutation: internal/meeting/runner.go transcribe, delete
// `warnings = append(warnings, WarnEchoDropped)` -> RED (the drop is silent);
// delete `m.EchoDropped = dropped` -> RED (the count is lost);
// delete the RawTranscriptJSON WriteAtomic -> RED (nothing to recover with).
func TestEchoDropIsWarnedCountedAndRecoverable(t *testing.T) {
	f := newFixture(t)
	f.r.Transcribe = func(_ context.Context, wav string) (*stt.Result, error) {
		start := 1.0
		if strings.HasPrefix(filepath.Base(wav), "me-") {
			start = 1.3
		}
		return &stt.Result{Words: words(start, "so the plan is to ship the release on friday after the review")}, nil
	}
	id := f.start(t, 20, 20, 5000, true)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	m := f.load(t, id)
	found := false
	for _, w := range m.Warnings {
		found = found || w == WarnEchoDropped
	}
	if !found || m.EchoDropped != 1 {
		t.Fatalf("warnings = %v, echo_dropped = %d; want %s and 1", m.Warnings, m.EchoDropped, WarnEchoDropped)
	}
	dir, _ := f.r.Store.Dir(id)
	raw, err := os.ReadFile(filepath.Join(dir, RawTranscriptJSON))
	if err != nil {
		t.Fatal("the pre-drop turns must be kept for recovery")
	}
	var turns []Turn
	if err := json.Unmarshal(raw, &turns); err != nil {
		t.Fatal(err)
	}
	var mine int
	for _, tu := range turns {
		if tu.Speaker == SpeakerMe {
			mine++
		}
	}
	if len(turns) != 2 || mine != 1 {
		t.Fatalf("raw turns = %+v; want the dropped me turn beside the far side's", turns)
	}
	var post []Turn
	trJSON, _ := os.ReadFile(filepath.Join(dir, TranscriptJSON))
	if err := json.Unmarshal(trJSON, &post); err != nil {
		t.Fatal(err)
	}
	if len(post) != 1 || post[0].Speaker != SpeakerThem {
		t.Fatalf("transcript.json = %+v; want only the far side's turn", post)
	}
}

// A failure on a later piece fails the meeting, and a retry resumes: the
// pieces already recognized are not recognized again.
// Mutation: internal/meeting/runner.go pieceWords, delete the cache read
// (`if raw, err := os.ReadFile(cache)` block) -> RED (everything is redone).
func TestRetryResumesFromTheCachedPieces(t *testing.T) {
	f := newFixture(t)
	good := f.r.Transcribe
	fail := true
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if fail && f.calls.Load() >= 2 {
			return nil, errors.New("engine crashed")
		}
		return good(ctx, wav)
	}
	id := f.start(t, 600, 0, 5000, false)
	if err := f.r.Process(context.Background(), id); err == nil {
		t.Fatal("want the engine failure")
	}
	if m := f.load(t, id); m.Status != StatusFailed || !strings.Contains(m.Error, "engine crashed") {
		t.Fatalf("manifest = %+v", m)
	}
	before := f.calls.Load()
	fail = false
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusQueued }); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if redone := f.calls.Load() - before; redone != 1 { // 3 pieces, 2 cached
		t.Fatalf("the retry recognized %d pieces, want only the failed one", redone)
	}
}

// A daemon shutdown mid-job is not a failure: the meeting stays resumable.
// Mutation: internal/meeting/runner.go stop, delete the `ctx.Err() != nil`
// guard -> RED (the shutdown marks the meeting failed).
func TestShutdownLeavesTheMeetingResumable(t *testing.T) {
	f := newFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { cancel(); return nil, ctx.Err() }
	id := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(ctx, id)
	if m := f.load(t, id); m.Status != StatusTranscribing {
		t.Fatalf("status = %s, want transcribing (resumable)", m.Status)
	}
}

func TestNotesWaitForTheModel(t *testing.T) {
	f := newFixture(t)
	f.notes = "model_missing"
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	m := f.load(t, id)
	if m.Status != StatusTranscribed || m.NotesPending != "model_missing" {
		t.Fatalf("manifest = %+v", m)
	}
	dir, _ := f.r.Store.Dir(id)
	if _, err := os.Stat(filepath.Join(dir, TranscriptMD)); err != nil {
		t.Fatal("the transcript must exist while notes wait")
	}
	f.notes = ""
	if _, err := f.r.RetryNotes(id); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusDone || m.NotesPending != "" {
		t.Fatalf("after the model arrived: %+v", m)
	}
}

func TestShortRecordingGetsNoModelCall(t *testing.T) {
	f := newFixture(t)
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) {
		return &stt.Result{Words: words(1, "hello hello")}, nil
	}
	id := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), id)
	if got := len(f.r.Chat.(*fakeChat).reqs); got != 0 {
		t.Fatalf("model calls = %d, want 0 for a transcript of a few words", got)
	}
	if m := f.load(t, id); m.Status != StatusDone {
		t.Fatalf("status = %s", m.Status)
	}
}

func TestRunProcessesTheQueueAndReportsActive(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	if f.r.Active() != 1 {
		t.Fatalf("Active = %d after Finish", f.r.Active())
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { f.r.Run(ctx); close(done) }()
	deadline := time.Now().Add(5 * time.Second)
	for f.load(t, id).Status != StatusDone && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
	if f.load(t, id).Status != StatusDone || f.r.Active() != 0 {
		t.Fatalf("status %s, active %d", f.load(t, id).Status, f.r.Active())
	}
}

// A recording whose app died is finished with the audio that reached the disk.
// Mutation: internal/meeting/runner.go finishIfStale, change `< staleRecording`
// to `> staleRecording` -> RED (a live recording would be cut, an orphan never).
func TestRecoverFinishesAnOrphanedRecordingButNotALiveOne(t *testing.T) {
	f := newFixture(t)
	orphan, dir, _ := f.r.Store.Create(Manifest{}, t0)
	writePCM(t, dir, MePCM, 10, 5000)
	old := t0.Add(5 * time.Second)
	_ = os.Chtimes(filepath.Join(dir, MePCM), old, old)
	_ = os.Chtimes(filepath.Join(dir, ManifestFile), old, old)
	live, ldir, _ := f.r.Store.Create(Manifest{}, f.now.Add(-30*time.Second))
	writePCM(t, ldir, MePCM, 10, 5000)
	_ = os.Chtimes(filepath.Join(ldir, MePCM), f.now.Add(-5*time.Second), f.now.Add(-5*time.Second))

	f.r.Recover()
	if m := f.load(t, orphan.ID); m.Status != StatusQueued || m.Ended == nil || !m.Ended.Equal(old) {
		t.Fatalf("orphan = %+v, want queued and ended at its last write", m)
	}
	if m := f.load(t, live.ID); m.Status != StatusRecording {
		t.Fatalf("a recording written 5 s ago must be left alone: %s", m.Status)
	}
}

func TestRecoverRequeuesWhatADeadDaemonLeft(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	f.r = NewRunner(f.r.Deps) // a fresh daemon: an empty queue
	f.r.Recover()
	if f.r.Active() != 1 {
		t.Fatalf("Active = %d, want the queued meeting back in the queue (%s)", f.r.Active(), id)
	}
}

// Audio goes after the retention period, and only when a transcript exists.
// Mutation: internal/meeting/retention.go SweepRetention, delete the
// transcript.json stat check -> RED (the only copy of a failed meeting's words
// is deleted).
func TestRetentionDeletesAudioNotText(t *testing.T) {
	f := newFixture(t)
	old := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), old)
	f.now = f.now.Add(40 * 24 * time.Hour) // retention is 30 days by default
	noTranscript, ndir, _ := f.r.Store.Create(Manifest{}, t0)
	writePCM(t, ndir, MePCM, 5, 5000)
	end := t0.Add(time.Hour)
	_, _ = f.r.Store.Update(noTranscript.ID, func(m *Manifest) { m.Ended, m.Status = &end, StatusTranscribed })

	if n := f.r.SweepRetention(); n != 1 {
		t.Fatalf("swept %d meetings, want 1", n)
	}
	dir, _ := f.r.Store.Dir(old)
	for _, gone := range []string{MePCM, ThemPCM} {
		if _, err := os.Stat(filepath.Join(dir, gone)); err == nil {
			t.Errorf("%s survived the sweep", gone)
		}
	}
	for _, kept := range []string{TranscriptMD, NotesMD, TranscriptJSON} {
		if _, err := os.Stat(filepath.Join(dir, kept)); err != nil {
			t.Errorf("%s was deleted: text is kept until the user deletes it", kept)
		}
	}
	if _, err := os.Stat(filepath.Join(ndir, MePCM)); err != nil {
		t.Error("audio of a meeting with no transcript must be kept")
	}
	if !f.load(t, old).AudioDeleted {
		t.Error("manifest must say the audio is gone")
	}
}

func TestRetentionZeroKeepsEverything(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), id)
	f.now = f.now.Add(3650 * 24 * time.Hour)
	if err := f.r.Store.SetSettings(Settings{RetentionDays: 0}); err != nil {
		t.Fatal(err)
	}
	if n := f.r.SweepRetention(); n != 0 {
		t.Fatalf("swept %d with retention 0 (never delete)", n)
	}
	if got := f.r.Store.Settings().RetentionDays; got != 0 {
		t.Fatalf("settings round trip = %d", got)
	}
}

// Speech the recognizer cannot read (it writes a transliteration or symbols)
// is warned, not silently summarized.
// Mutation: internal/meeting/runner.go transcribe, delete the `script == ""`
// block -> RED.
func TestUnreadableScriptIsWarned(t *testing.T) {
	f := newFixture(t)
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) {
		var w []stt.Word
		for i := 0; i < 40; i++ {
			w = append(w, stt.Word{W: "12345", S: float64(i) * 0.4, E: float64(i)*0.4 + 0.3})
		}
		return &stt.Result{Words: w}, nil
	}
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(context.Background(), id)
	got := f.load(t, id)
	found := false
	for _, w := range got.Warnings {
		found = found || w == WarnLanguage
	}
	if !found {
		t.Fatalf("warnings = %v, want %s", got.Warnings, WarnLanguage)
	}
}
