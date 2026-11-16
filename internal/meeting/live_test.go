package meeting

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// pcmBuilder lays out a channel file: loud stretches (a square wave well above silentRMS) and quiet ones.
type pcmBuilder struct{ s []int16 }

func (b *pcmBuilder) speech(sec float64) *pcmBuilder {
	for range int(sec * SampleRate) {
		b.s = append(b.s, 5000)
	}
	return b
}

func (b *pcmBuilder) quiet(sec float64) *pcmBuilder {
	b.s = append(b.s, make([]int16, int(sec*SampleRate))...)
	return b
}

func (b *pcmBuilder) bytes() []byte {
	out := make([]byte, len(b.s)*2)
	for i, v := range b.s {
		binary.LittleEndian.PutUint16(out[2*i:], uint16(v))
	}
	return out
}

func writeChannel(t *testing.T, dir, name string, b *pcmBuilder) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), b.bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}

func appendChannel(t *testing.T, dir, name string, b *pcmBuilder) {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(dir, name), os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	if _, err := f.Write(b.bytes()); err != nil {
		t.Fatal(err)
	}
}

func TestNextLiveChunkClosesAfterQuietAndPadsTheSpeech(t *testing.T) {
	// 2 s quiet, 3 s speech, 1 s quiet: closes on the quiet, drops the leading quiet, keeps 0.2 s of pad each side.
	b := (&pcmBuilder{}).quiet(2).speech(3).quiet(1)
	consumed, span, ok := nextLiveChunk(b.s, 1000)
	if !ok {
		t.Fatal("a stretch of speech followed by 0.6 s of quiet did not close")
	}
	wantFrom, wantTo := 1000+int(1.8*SampleRate), 1000+int(5.2*SampleRate)
	if span.From != wantFrom || span.To != wantTo || consumed != wantTo {
		t.Fatalf("span %+v consumed %d, want [%d,%d) consumed %d", span, consumed, wantFrom, wantTo, wantTo)
	}
}

func TestNextLiveChunkWaitsForTheQuietAndKeepsTheSpeech(t *testing.T) {
	b := (&pcmBuilder{}).quiet(2).speech(3).quiet(0.4) // only 0.4 s of quiet: the speaker may go on
	consumed, _, ok := nextLiveChunk(b.s, 0)
	if ok {
		t.Fatal("closed a stretch that has had 0.4 s of quiet")
	}
	if want := int(1.8 * SampleRate); consumed != want {
		t.Fatalf("consumed %d, want %d: the speech start (less its pad) must be kept for the next look", consumed, want)
	}
}

func TestNextLiveChunkOfOnlyQuietIsConsumedWithoutAChunk(t *testing.T) {
	consumed, _, ok := nextLiveChunk((&pcmBuilder{}).quiet(5).s, 0)
	if ok || consumed != 5*SampleRate {
		t.Fatalf("ok=%v consumed=%d, want no chunk and everything consumed", ok, consumed)
	}
}

// A speaker who never pauses is cut at the cap, at the quietest point of the last 3 s: a decode is bounded.
func TestNextLiveChunkCutsContinuousSpeechAtTheCap(t *testing.T) {
	// 12 s of speech with a dip of 0.5 s quiet-ish (not enough to close, below the loud floor) at 8 s.
	b := (&pcmBuilder{}).speech(8).quiet(0.5).speech(5)
	_, span, ok := nextLiveChunk(b.s, 0)
	if !ok {
		t.Fatal("12 s of continuous speech did not close")
	}
	if got := span.To - span.From; got > liveMaxSamples {
		t.Fatalf("chunk is %.1f s, over the 10 s cap", float64(got)/SampleRate)
	}
	if span.To < 8*SampleRate || span.To > int(8.6*SampleRate) {
		t.Fatalf("cut at %.2f s, want inside the quiet dip at 8.0-8.5 s", float64(span.To)/SampleRate)
	}
}

func TestLiveLogSeqContinuesAfterReopenAndTornTailIsCut(t *testing.T) {
	dir := t.TempDir()
	l, err := OpenLiveLog(dir)
	if err != nil {
		t.Fatal(err)
	}
	for i, ch := range []string{LiveMe, LiveThem, LiveMe} {
		seg, err := l.Append(ch, float64(i), float64(i)+0.5, fmt.Sprintf("line %d", i+1))
		if err != nil || seg.Seq != i+1 {
			t.Fatalf("append %d: seq %d err %v", i+1, seg.Seq, err)
		}
	}
	// a crash mid-write leaves a half line
	f, _ := os.OpenFile(filepath.Join(dir, LiveJSONL), os.O_APPEND|os.O_WRONLY, 0o600)
	_, _ = f.WriteString(`{"seq":4,"channel":"me","sta`)
	_ = f.Close()

	l2, err := OpenLiveLog(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := l2.Resume(LiveMe); got != 2.5 {
		t.Fatalf("resume for me = %v, want 2.5", got)
	}
	seg, err := l2.Append(LiveThem, 3, 4, "after the restart")
	if err != nil || seg.Seq != 4 {
		t.Fatalf("seq after reopen = %d (%v), want 4", seg.Seq, err)
	}
	got, next, err := ReadLive(dir, 0, 0)
	if err != nil || len(got) != 4 || next != 4 || got[3].Text != "after the restart" {
		t.Fatalf("read = %+v next %d err %v: the torn line must be gone and the new one whole", got, next, err)
	}
}

// The cursor: polling with the returned next yields every caption exactly once, in order, whatever the page size.
// Mutation: internal/meeting/live.go ReadLive, `seg.Seq <= after` -> `seg.Seq < after` -> RED (the last caption of
// each poll comes again); `next = seg.Seq` -> `next = seg.Seq + 1` -> RED (one caption skipped per poll).
func TestReadLiveCursorNeverRepeatsAndNeverSkips(t *testing.T) {
	dir := t.TempDir()
	l, _ := OpenLiveLog(dir)
	for i := range 23 {
		if _, err := l.Append(LiveMe, float64(i), float64(i)+1, fmt.Sprintf("t%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	for _, page := range []int{0, 1, 5, 7, 100} {
		var seen []int
		after := 0
		for range 40 {
			segs, next, err := ReadLive(dir, after, page)
			if err != nil {
				t.Fatal(err)
			}
			for _, s := range segs {
				seen = append(seen, s.Seq)
			}
			if len(segs) == 0 && next != after {
				t.Fatalf("page %d: an empty poll moved the cursor %d -> %d", page, after, next)
			}
			after = next
		}
		want := make([]int, 23)
		for i := range want {
			want[i] = i + 1
		}
		if !slices.Equal(seen, want) {
			t.Fatalf("page %d: seen %v, want 1..23 once each", page, seen)
		}
	}
}

// A reader polling while the writer appends sees each caption once and in order, and never a half line.
func TestReadLiveWhileWriting(t *testing.T) {
	dir := t.TempDir()
	l, _ := OpenLiveLog(dir)
	const n = 300
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := range n {
			if _, err := l.Append(LiveThem, float64(i), float64(i)+1, "x"); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	var seen []int
	after := 0
	deadline := time.Now().Add(10 * time.Second)
	for len(seen) < n {
		if time.Now().After(deadline) {
			t.Fatalf("saw only %d of %d captions: one was skipped", len(seen), n)
		}
		segs, next, err := ReadLive(dir, after, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, s := range segs {
			seen = append(seen, s.Seq)
		}
		after = next
	}
	<-done
	for i, s := range seen {
		if s != i+1 {
			t.Fatalf("seen[%d] = %d, want %d (repeat or skip)", i, s, i+1)
		}
	}
}

// liveRig is a worker over fakes, running on a recording whose files the test grows.
type liveRig struct {
	dir       string
	recording atomic.Bool
	hold      atomic.Value // string
	holdCalls atomic.Int32
	mu        sync.Mutex
	decoded   []int // wav byte lengths, in order
	decodeErr func(n int) error
	text      func(n int) string
	w         *LiveWorker
}

func newLiveRig(t *testing.T) *liveRig {
	t.Helper()
	r := &liveRig{dir: t.TempDir()}
	r.recording.Store(true)
	r.hold.Store("")
	r.text = func(n int) string { return fmt.Sprintf("caption %d", n) }
	w, err := NewLiveWorker(LiveDeps{
		Dir:       r.dir,
		Recording: r.recording.Load,
		Hold:      func() string { r.holdCalls.Add(1); return r.hold.Load().(string) },
		Decode: func(_ context.Context, wav []byte) (string, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.decoded = append(r.decoded, len(wav))
			if r.decodeErr != nil {
				if err := r.decodeErr(len(r.decoded)); err != nil {
					return "", err
				}
			}
			return r.text(len(r.decoded)), nil
		},
		Tick: 2 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	r.w = w
	return r
}

func (r *liveRig) run(t *testing.T) (stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.w.Run(ctx); close(done) }()
	var once sync.Once
	stop = func() {
		once.Do(func() {
			cancel()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Error("the worker did not stop")
			}
		})
	}
	t.Cleanup(stop)
	return stop
}

func (r *liveRig) calls() int { r.mu.Lock(); defer r.mu.Unlock(); return len(r.decoded) }

func (r *liveRig) lines(t *testing.T) []LiveSegment {
	t.Helper()
	segs, _, err := ReadLive(r.dir, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	return segs
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// Both channels, oldest first: the captions come out in the order they were spoken, each with the channel and the
// seconds it was said.
func TestLiveWorkerCaptionsBothChannelsInSpokenOrder(t *testing.T) {
	r := newLiveRig(t)
	writeChannel(t, r.dir, ThemPCM, (&pcmBuilder{}).quiet(1).speech(2).quiet(1))
	writeChannel(t, r.dir, MePCM, (&pcmBuilder{}).quiet(5).speech(2).quiet(1))
	r.run(t)
	waitFor(t, "two captions", func() bool { return len(r.lines(t)) == 2 })
	got := r.lines(t)
	if got[0].Channel != LiveThem || got[1].Channel != LiveMe || got[0].Start >= got[1].Start {
		t.Fatalf("captions = %+v, want them (said first) then me", got)
	}
	if got[0].Seq != 1 || got[1].Seq != 2 || got[0].Start < 0.7 || got[0].End > 3.4 {
		t.Fatalf("captions = %+v, want seq 1,2 and the first said at about 1.0-3.0 s", got)
	}
}

// The dictation guard: a hold means no decode at all, and what was held back is captioned afterwards — nothing lost.
func TestLiveWorkerDecodesNothingWhileHeldAndLosesNothingAfter(t *testing.T) {
	r := newLiveRig(t)
	r.hold.Store("dictation")
	writeChannel(t, r.dir, MePCM, (&pcmBuilder{}).quiet(1).speech(2).quiet(1).speech(2).quiet(1))
	r.run(t)
	time.Sleep(150 * time.Millisecond)
	if n := r.calls(); n != 0 {
		t.Fatalf("%d decodes while held", n)
	}
	if st := r.w.State(); st.Paused != "dictation" || !st.Lagging() {
		t.Fatalf("state = %+v, want paused for dictation and lagging", st)
	}
	r.hold.Store("")
	waitFor(t, "both stretches captioned", func() bool { return len(r.lines(t)) == 2 })
}

// The hold is checked right before the decode, not only when the chunk is picked: a dictation that begins in
// between is seen by the very next chunk.
// Mutation: internal/meeting/live.go step, delete the `if hold = w.d.Hold(); hold != "" {` block (the recheck) -> RED.
func TestLiveWorkerRechecksTheHoldRightBeforeTheDecode(t *testing.T) {
	r := newLiveRig(t)
	var asked atomic.Int32
	r.w.d.Hold = func() string {
		// the look at the files says go; the check just before the decode says a dictation began
		if asked.Add(1)%2 == 1 {
			return ""
		}
		return "dictation"
	}
	writeChannel(t, r.dir, MePCM, (&pcmBuilder{}).quiet(1).speech(2).quiet(1))
	r.run(t)
	time.Sleep(150 * time.Millisecond)
	if n := r.calls(); n != 0 {
		t.Fatalf("%d decodes although the hold was up at the moment of each", n)
	}
	if asked.Load() < 4 {
		t.Fatalf("the hold was asked only %d times", asked.Load())
	}
}

// A recognizer that is down never costs a caption: the chunk waits, and is captioned when it is back. Only the
// recognizer refusing the same audio again and again gives it up.
func TestLiveWorkerKeepsTheChunkWhileTheRecognizerIsDownAndSkipsOnlyARefusedOne(t *testing.T) {
	r := newLiveRig(t)
	r.decodeErr = func(n int) error {
		if n <= 8 {
			return errors.New("the speech server is cooling down") // not a verdict on the audio
		}
		return nil
	}
	writeChannel(t, r.dir, MePCM, (&pcmBuilder{}).quiet(1).speech(2).quiet(1))
	r.run(t)
	waitFor(t, "the caption after 8 failures", func() bool { return len(r.lines(t)) == 1 })
	if r.calls() != 9 {
		t.Fatalf("decodes = %d, want 8 failures and the 9th succeeding on the same chunk", r.calls())
	}

	r2 := newLiveRig(t)
	r2.decodeErr = func(n int) error {
		if n <= liveRejects {
			return fmt.Errorf("%w: 500", ErrLiveRejected)
		}
		return nil
	}
	writeChannel(t, r2.dir, MePCM, (&pcmBuilder{}).quiet(1).speech(2).quiet(1).speech(2).quiet(1))
	r2.run(t)
	waitFor(t, "the second stretch captioned", func() bool { return len(r2.lines(t)) == 1 })
	segs := r2.lines(t)
	if len(segs) != 1 || segs[0].Start < 3 {
		t.Fatalf("captions = %+v: the refused first stretch is given up, the second is captioned", segs)
	}
}

// Audio keeps arriving while the worker runs, and a restart in the middle of the call resumes where the file says:
// no stretch is captioned twice.
func TestLiveWorkerFollowsAGrowingFileAndAResumeDoesNotRepeat(t *testing.T) {
	r := newLiveRig(t)
	writeChannel(t, r.dir, MePCM, (&pcmBuilder{}).quiet(1).speech(2).quiet(1))
	stop := r.run(t)
	waitFor(t, "first caption", func() bool { return len(r.lines(t)) == 1 })
	stop()

	w2, err := NewLiveWorker(LiveDeps{
		Dir: r.dir, Recording: r.recording.Load, Hold: func() string { return "" }, Tick: 2 * time.Millisecond,
		Decode: func(context.Context, []byte) (string, error) {
			r.mu.Lock()
			r.decoded = append(r.decoded, 0)
			r.mu.Unlock()
			return "second", nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	r.w = w2
	r.run(t)
	time.Sleep(100 * time.Millisecond)
	if got := len(r.lines(t)); got != 1 {
		t.Fatalf("%d captions after the restart with no new speech, want 1 (no repeat)", got)
	}
	appendChannel(t, r.dir, MePCM, (&pcmBuilder{}).speech(2).quiet(1))
	waitFor(t, "the caption of the new speech", func() bool { return len(r.lines(t)) == 2 })
	if got := r.lines(t); got[1].Seq != 2 || got[1].Start < 3.5 {
		t.Fatalf("captions = %+v", got)
	}
}

// A worker that starts late, or falls behind, jumps to the newest audio instead of decoding minutes of backlog.
func TestLiveWorkerJumpsAheadWhenTooFarBehind(t *testing.T) {
	r := newLiveRig(t)
	b := &pcmBuilder{}
	for range 30 { // 30 x 4 s = 120 s of short sentences
		b.speech(2).quiet(2)
	}
	writeChannel(t, r.dir, MePCM, b)
	r.run(t)
	waitFor(t, "captions", func() bool { return r.calls() >= 2 })
	time.Sleep(100 * time.Millisecond)
	if n := r.calls(); n > 4 {
		t.Fatalf("%d decodes for 120 s of backlog, want only the last ~10 s", n)
	}
	for _, s := range r.lines(t) {
		if s.Start < 100 {
			t.Fatalf("caption of second %.0f: the backlog before the last 10 s must be skipped", s.Start)
		}
	}
}

// The worker ends with the recording: once the meeting is no longer recording it neither decodes nor appends.
// Mutation: internal/meeting/live.go Run, `for ctx.Err() == nil && w.d.Recording() {` -> `for ctx.Err() == nil {` -> RED.
func TestLiveWorkerEndsWhenTheMeetingStopsRecording(t *testing.T) {
	r := newLiveRig(t)
	writeChannel(t, r.dir, MePCM, (&pcmBuilder{}).quiet(1).speech(2).quiet(1))
	ctx := context.Background()
	done := make(chan struct{})
	go func() { r.w.Run(ctx); close(done) }()
	waitFor(t, "a caption", func() bool { return len(r.lines(t)) == 1 })
	r.recording.Store(false)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("the worker kept running after the recording ended")
	}
}

// Live on or off, the final pass is the same: same files, same recognizer calls, and live.jsonl the only addition.
func TestFinalPassIsTheSameWithLiveCaptionsOn(t *testing.T) {
	run := func(live bool) (files map[string]string, calls int32) {
		f := newFixture(t)
		m, dir, err := f.r.Store.Create(Manifest{Title: "Plan", Labels: Labels{Me: "Anatoly", Them: "Other"}}, t0)
		if err != nil {
			t.Fatal(err)
		}
		writePCM(t, dir, MePCM, 40, 5000)
		writePCM(t, dir, ThemPCM, 40, 5000)
		if live {
			w, err := NewLiveWorker(LiveDeps{
				Dir: dir,
				Recording: func() bool {
					cur, err := f.r.Store.Load(m.ID)
					return err == nil && cur.Status == StatusRecording
				},
				Hold:   func() string { return "" },
				Decode: func(context.Context, []byte) (string, error) { return "a live caption", nil },
				Tick:   2 * time.Millisecond,
			})
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			go func() { w.Run(context.Background()); close(done) }()
			waitFor(t, "live captions", func() bool { s, _, _ := ReadLive(dir, 0, 0); return len(s) >= 2 })
			if _, err := f.r.Finish(m.ID, t0.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("the live worker outlived the recording")
			}
		} else if _, err := f.r.Finish(m.ID, t0.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
		if err := f.r.Process(context.Background(), m.ID); err != nil {
			t.Fatal(err)
		}
		files = map[string]string{}
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if e.Name() == LiveJSONL || e.Name() == ManifestFile {
				continue // the manifest holds the meeting's id
			}
			raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				continue // a directory (work/)
			}
			files[e.Name()] = string(raw)
		}
		if live {
			if _, err := os.Stat(filepath.Join(dir, LiveJSONL)); err != nil {
				t.Fatalf("no live.jsonl: %v", err)
			}
		}
		return files, f.calls.Load()
	}
	offFiles, offCalls := run(false)
	onFiles, onCalls := run(true)
	if offCalls != onCalls {
		t.Fatalf("recognizer calls: %d with live off, %d with it on", offCalls, onCalls)
	}
	if len(offFiles) < 4 {
		t.Fatalf("the baseline made only %v", offFiles)
	}
	for name, want := range offFiles {
		if got, ok := onFiles[name]; !ok || got != want {
			t.Errorf("%s differs with live captions on", name)
		}
	}
	for name := range onFiles {
		if _, ok := offFiles[name]; !ok {
			t.Errorf("%s exists only with live captions on", name)
		}
	}
}
