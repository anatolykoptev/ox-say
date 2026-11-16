package meeting

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/pcm"
)

// Live captions: while a meeting records, the finished stretches of speech of each channel are recognized and
// appended to LiveJSONL, one JSON line each, so the window can show the conversation a few seconds behind. It is a
// preview and never the record: the final pass (Runner.Process) reads the audio files exactly as it did before and
// does not look at this file. The worker below never writes the manifest, the transcript or work/.

// LiveJSONL is the live captions of one meeting, an append-only file of LiveSegment lines. It goes with the audio
// when retention removes it: it is the same speech as text.
const LiveJSONL = "live.jsonl"

// Channel codes of a LiveSegment; the app maps them to the meeting's labels.
const (
	LiveMe   = "me"
	LiveThem = "them"
)

// LiveSegment is one caption. Seq counts from 1 across the whole file and only grows, so a client that remembers
// the last Seq it saw gets every later line exactly once. Start and End are seconds into the recording.
type LiveSegment struct {
	Seq     int     `json:"seq"`
	Channel string  `json:"channel"`
	Start   float64 `json:"start"`
	End     float64 `json:"end"`
	Text    string  `json:"text"`
}

// LiveLog is the single appender of one meeting's LiveJSONL. Seq is assigned here, under the lock, so the order
// in the file is the order of Seq.
type LiveLog struct {
	path string
	mu   sync.Mutex
	next int
	ends map[string]float64
	// torn: a failed write may have left part of a line behind. The next append starts on a fresh line, so the
	// part stays one line that does not parse (readers skip it) and never glues itself to a caption.
	torn bool
	// write is the append; a test seam (a disk that fills halfway through a line).
	write func(f *os.File, b []byte) (int, error)
}

// OpenLiveLog opens the meeting's live file for appending. A daemon that restarted mid-call finds what it wrote:
// the next Seq continues the file and Resume tells where each channel was read to. A torn last line (no newline: a
// crash mid-write) is cut off, so the next append cannot glue itself to it.
func OpenLiveLog(dir string) (*LiveLog, error) {
	l := &LiveLog{path: filepath.Join(dir, LiveJSONL), next: 1, ends: map[string]float64{}, write: (*os.File).Write}
	raw, err := os.ReadFile(l.path)
	if errors.Is(err, os.ErrNotExist) {
		return l, nil
	}
	if err != nil {
		return nil, fmt.Errorf("meeting: live captions: %w", err)
	}
	whole := raw[:bytes.LastIndexByte(raw, '\n')+1]
	if len(whole) != len(raw) {
		if err := os.Truncate(l.path, int64(len(whole))); err != nil {
			return nil, fmt.Errorf("meeting: live captions: %w", err)
		}
	}
	for _, seg := range parseLive(whole) {
		l.next = max(l.next, seg.Seq+1)
		l.ends[seg.Channel] = max(l.ends[seg.Channel], seg.End)
	}
	return l, nil
}

// Resume is the second up to which a channel's speech has been captioned (0: nothing yet).
func (l *LiveLog) Resume(channel string) float64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.ends[channel]
}

// Append writes one caption and returns it with its Seq.
func (l *LiveLog) Append(channel string, start, end float64, text string) (LiveSegment, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	seg := LiveSegment{Seq: l.next, Channel: channel, Start: round3(start), End: round3(end), Text: text}
	line, err := json.Marshal(seg)
	if err != nil {
		return LiveSegment{}, err
	}
	f, err := os.OpenFile(l.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return LiveSegment{}, fmt.Errorf("meeting: live captions: %w", err)
	}
	out := append(line, '\n')
	if l.torn {
		out = append([]byte{'\n'}, out...)
	}
	n, werr := l.write(f, out)
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil && n == len(out) {
		werr = nil // the whole line is on disk; only the close complained
	}
	if werr != nil {
		l.torn = l.torn || n > 0
		return LiveSegment{}, fmt.Errorf("meeting: live captions: %w", werr)
	}
	l.torn = false
	l.next++
	l.ends[channel] = max(l.ends[channel], seg.End)
	return seg, nil
}

func round3(x float64) float64 { return math.Round(x*1000) / 1000 }

// parseLive reads the complete lines of a live file; a line that does not parse is skipped.
func parseLive(raw []byte) []LiveSegment {
	var out []LiveSegment
	for _, line := range bytes.Split(raw, []byte{'\n'}) {
		if len(line) == 0 {
			continue
		}
		var seg LiveSegment
		if json.Unmarshal(line, &seg) != nil || seg.Seq < 1 {
			continue
		}
		out = append(out, seg)
	}
	return out
}

// ReadLive returns the captions with Seq greater than after, oldest first, at most limit of them (0: all), and
// the cursor to ask with next: the Seq of the last caption returned, or after when there is none. Only lines that
// end in a newline are read, so a line being written is never half-served: the next poll gets it whole. A meeting
// with no live file has no captions, not an error.
func ReadLive(dir string, after, limit int) ([]LiveSegment, int, error) {
	raw, err := os.ReadFile(filepath.Join(dir, LiveJSONL))
	if errors.Is(err, os.ErrNotExist) {
		return []LiveSegment{}, after, nil
	}
	if err != nil {
		return nil, after, fmt.Errorf("meeting: live captions: %w", err)
	}
	out := []LiveSegment{}
	next := after
	for _, seg := range parseLive(raw[:bytes.LastIndexByte(raw, '\n')+1]) {
		if seg.Seq <= after {
			continue
		}
		if limit > 0 && len(out) >= limit {
			break
		}
		out = append(out, seg)
		next = seg.Seq
	}
	return out, next, nil
}

// The chunker: where a stretch of speech ends, found on the same 100 ms RMS windows and the same silentRMS floor
// the final pass uses to tell speech from silence (Silent). A chunk closes after liveClose windows of quiet, or at
// liveMaxSamples at the quietest point of its last liveCutLook, so a decode is bounded: that bound is the longest a
// dictation can wait behind a caption.
const (
	liveClose      = 6 // windows of quiet (0.6 s) that end a chunk
	livePadWin     = 2 // windows of quiet kept either side of the speech
	liveMaxSamples = 10 * SampleRate
	liveCutLook    = 3 * SampleRate
	// liveReadSamples is how far past the cursor one look reaches: a chunk of at most liveMaxSamples that starts
	// after up to as much leading quiet.
	liveReadSamples = 2 * liveMaxSamples
	// liveMaxBacklog is how far behind a channel may fall before the worker jumps ahead; liveCatchUp is how much
	// of the newest audio it keeps then.
	liveMaxBacklog = 60 * SampleRate
	liveCatchUp    = 10 * SampleRate
	// liveLagging is the backlog the app is told about.
	liveLagging = 15 * SampleRate
	// liveRejects is how many times the server may refuse the same chunk before it is given up.
	liveRejects = 3
	// liveMaxWait caps the back-off after a transient failure.
	liveMaxWait = 10 * time.Second
)

func windowLoud(w []int16) bool {
	var sum float64
	for _, s := range w {
		sum += float64(s) * float64(s)
	}
	return math.Sqrt(sum/rmsWindow) > silentRMS
}

// nextLiveChunk looks at s, the samples that start at absolute sample index base, and answers: consumed, the
// absolute index before which nothing needs another look (leading quiet is dropped); and, when a stretch of speech
// has closed, its span. Without a closed stretch the span is empty and consumed stops where the speech begins.
func nextLiveChunk(s []int16, base int) (consumed int, span Span, ok bool) {
	nw := len(s) / rmsWindow
	loud := make([]bool, nw)
	first := -1
	for w := range nw {
		if loud[w] = windowLoud(s[w*rmsWindow : (w+1)*rmsWindow]); loud[w] && first < 0 {
			first = w
		}
	}
	if first < 0 {
		return base + nw*rmsWindow, Span{}, false
	}
	start := max(0, first-livePadWin) * rmsWindow
	last := first
	for w := first; w < nw; w++ {
		if loud[w] {
			last = w
		}
		if w-last >= liveClose {
			end := min(nw, last+1+livePadWin) * rmsWindow
			return base + end, Span{base + start, base + end}, true
		}
		if to := (w + 1) * rmsWindow; to-start >= liveMaxSamples {
			lo := max(start+SampleRate, to-liveCutLook)
			clip := pcm.Clip{Rate: SampleRate, S: s[lo:to]}
			cut := min(to, lo+clip.QuietestWindow(quietWindow)+quietWindow/2)
			return base + cut, Span{base + start, base + cut}, true
		}
	}
	return base + start, Span{}, false
}

// ErrLiveRejected marks a decode failure that is the recognizer's verdict on this audio (it answered, with an
// error). Anything else — the recognizer is off, cooling down, unreachable — says nothing about the audio, and the
// worker keeps the chunk and tries again later.
var ErrLiveRejected = errors.New("meeting: the recognizer refused this audio")

// ErrLiveHeld is what Decode answers when, at the moment it was about to run, a hold had begun (a dictation, memory
// pressure): nothing was decoded, nothing is wrong, and the chunk stays for the next look.
var ErrLiveHeld = errors.New("meeting: live captions are held")

// LiveDeps is what a LiveWorker needs from outside.
type LiveDeps struct {
	// Dir is the meeting's directory.
	Dir string
	// Recording reports whether the meeting is still being recorded; the worker ends when it is not.
	Recording func() bool
	// Hold returns "" when a chunk may be decoded now and otherwise why not ("dictation", "memory", "power"). It is
	// asked right before every decode, so a hold that starts between two chunks is seen by the next one.
	Hold func() string
	// Decode recognizes one 16 kHz mono WAV and returns its text. It must be the resident recognizer only.
	Decode func(ctx context.Context, wav []byte) (string, error)
	// Correct is the user's glossary applied to a caption's text; nil: none.
	Correct func(string) string
	Log     *slog.Logger
	// Tick is how often the worker looks at the files when there is nothing to do; 0 means a second.
	Tick time.Duration
}

// LiveState is what the worker reports to the app.
type LiveState struct {
	// Paused is the reason a caption was not decoded the last time the worker looked, "" when it ran.
	Paused string
	// BehindS is how many seconds of the longer-waiting channel are not captioned yet.
	BehindS float64
	// Problem is "recognizer" while the recognizer cannot be reached.
	Problem string
}

// Lagging reports whether the captions are behind enough for the app to say so.
func (s LiveState) Lagging() bool {
	return s.Paused != "" || s.Problem != "" || s.BehindS > float64(liveLagging)/SampleRate
}

type liveChannel struct {
	code string
	file string
	off  int // samples already dealt with
}

// LiveWorker captions one recording. One chunk is decoded at a time, the oldest of the two channels first.
type LiveWorker struct {
	d     LiveDeps
	log   *LiveLog
	chans []*liveChannel

	mu    sync.Mutex
	state LiveState

	// rejected counts consecutive refusals of the chunk starting at rejectedAt on rejectedCh.
	rejectedCh string
	rejectedAt int
	rejected   int
	wait       time.Duration
}

// NewLiveWorker opens the meeting's live file and sets each channel's cursor where the file says it stopped.
func NewLiveWorker(d LiveDeps) (*LiveWorker, error) {
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if d.Tick <= 0 {
		d.Tick = time.Second
	}
	log, err := OpenLiveLog(d.Dir)
	if err != nil {
		return nil, err
	}
	w := &LiveWorker{d: d, log: log}
	for _, c := range []struct{ code, file string }{{LiveMe, MePCM}, {LiveThem, ThemPCM}} {
		w.chans = append(w.chans, &liveChannel{code: c.code, file: filepath.Join(d.Dir, c.file), off: int(math.Round(log.Resume(c.code) * SampleRate))})
	}
	return w, nil
}

// State is the worker's report; safe to call from any goroutine.
func (w *LiveWorker) State() LiveState {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.state
}

func (w *LiveWorker) setState(f func(*LiveState)) {
	w.mu.Lock()
	f(&w.state)
	w.mu.Unlock()
}

// Run captions until ctx ends or the meeting stops recording.
func (w *LiveWorker) Run(ctx context.Context) {
	for ctx.Err() == nil && w.d.Recording() {
		wait := w.step(ctx)
		if wait <= 0 {
			continue
		}
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
		case <-t.C:
		}
		t.Stop()
	}
}

type liveCand struct {
	ch       *liveChannel
	span     Span
	consumed int
}

// step does one look at both channels and at most one decode; it returns how long to wait before the next.
func (w *LiveWorker) step(ctx context.Context) time.Duration {
	hold := w.d.Hold()
	var cands []liveCand
	var behind int
	for _, ch := range w.chans {
		avail := w.avail(ch)
		ch.off = min(ch.off, avail) // a channel file that was cut short (the writer's last step) is never read past its end
		if avail-ch.off > liveMaxBacklog {
			ch.off = avail - liveCatchUp
		}
		behind = max(behind, avail-ch.off)
		if hold != "" {
			continue
		}
		clip, err := w.read(ch, Span{ch.off, min(avail, ch.off+liveReadSamples)})
		if err != nil {
			continue
		}
		consumed, span, ok := nextLiveChunk(clip.S, ch.off)
		if !ok {
			ch.off = max(ch.off, consumed)
			continue
		}
		cands = append(cands, liveCand{ch, span, consumed})
	}
	w.setState(func(s *LiveState) { s.Paused, s.BehindS = hold, float64(behind)/SampleRate })
	if hold != "" || len(cands) == 0 {
		return w.d.Tick
	}
	c := cands[0]
	for _, o := range cands[1:] {
		if o.span.From < c.span.From {
			c = o
		}
	}
	// The check that guards the dictation: right before the decode, never earlier.
	if hold = w.d.Hold(); hold != "" {
		w.setState(func(s *LiveState) { s.Paused = hold })
		return w.d.Tick
	}
	return w.decode(ctx, c)
}

func (w *LiveWorker) avail(ch *liveChannel) int {
	st, err := os.Stat(ch.file)
	if err != nil {
		return 0
	}
	return int(st.Size() / bytesPerSample)
}

func (w *LiveWorker) read(ch *liveChannel, s Span) (pcm.Clip, error) {
	f, err := os.Open(ch.file)
	if err != nil {
		return pcm.Clip{}, err
	}
	defer func() { _ = f.Close() }()
	return ReadClip(f, s)
}

func (w *LiveWorker) decode(ctx context.Context, c liveCand) time.Duration {
	clip, err := w.read(c.ch, c.span)
	if err != nil {
		return w.d.Tick
	}
	if Silent(clip) { // a click, not speech: nothing to caption
		c.ch.off = c.consumed
		return 0
	}
	text, err := w.d.Decode(ctx, clip.Encode())
	switch {
	case ctx.Err() != nil:
		return 0
	case errors.Is(err, ErrLiveHeld):
		return w.d.Tick
	case errors.Is(err, ErrLiveRejected):
		if w.rejectedCh != c.ch.code || w.rejectedAt != c.span.From {
			w.rejectedCh, w.rejectedAt, w.rejected = c.ch.code, c.span.From, 0
		}
		if w.rejected++; w.rejected >= liveRejects {
			w.d.Log.Warn("meeting: live captions gave up on one stretch of speech", slog.String("channel", c.ch.code))
			c.ch.off = c.consumed
			w.rejected = 0
		}
		return w.back()
	case err != nil:
		w.setState(func(s *LiveState) { s.Problem = "recognizer" })
		return w.back()
	}
	w.wait = 0
	w.setState(func(s *LiveState) { s.Problem = "" })
	if w.d.Correct != nil {
		text = w.d.Correct(text)
	}
	if text = strings.TrimSpace(text); text != "" {
		if _, err := w.log.Append(c.ch.code, float64(c.span.From)/SampleRate, float64(c.span.To)/SampleRate, text); err != nil {
			w.d.Log.Warn("meeting: live captions cannot write", slog.Any("error", err))
			w.setState(func(s *LiveState) { s.Problem = "disk" })
			return w.back()
		}
	}
	c.ch.off = c.consumed
	return 0
}

// back is the wait after a failed decode: doubling from a tick up to liveMaxWait.
func (w *LiveWorker) back() time.Duration {
	if w.wait == 0 {
		w.wait = w.d.Tick
	} else {
		w.wait = min(2*w.wait, liveMaxWait)
	}
	return w.wait
}
