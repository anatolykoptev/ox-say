package daemon

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

// Live captions (#527): while a meeting records, a worker per recording captions the finished stretches of speech
// of each channel into the meeting's live.jsonl (meeting.LiveWorker); GET /v1/meetings/{id}/live reads them.
//
// What it must never do:
//   - make a dictation wait: liveHold is asked right before every decode and holds while anything interactive is in
//     flight, within interactiveQuiet of the last one, or a dictation session is open. One chunk is decoded at a
//     time and a chunk is at most 10 s, so the longest a dictation can wait is one decode of one chunk that began
//     before the hotkey: 0.05-0.09 s on Apple Silicon, 0.7-1.3 s on an Intel CPU (docs/performance.md).
//   - load a second model: the decode goes to the resident ox-stt server only (stt.TranscribeWAVViaServer), never
//     the per-call CLI. While the Mac is under memory pressure nothing is decoded and the server is not even asked
//     for, so it can idle-stop.
//   - touch the final pass: the worker reads the two audio files and writes live.jsonl and nothing else.

// livePressureHold is the macOS memory-pressure level (kern.memorystatus_vm_pressure_level: 1 normal, 2 warning,
// 4 critical) from which live captions stop.
const livePressureHold = 2

// livePowerTTL is how long a read of Low Power Mode is trusted: pmset is a subprocess.
const livePowerTTL = 30 * time.Second

// memoryPressureLevel reads the pressure level; 0 (unknown) never holds. A var so a test can set it.
var memoryPressureLevel = readMemoryPressure

// liveEnabled is whether live captions run for a new recording: the user's choice, or when they never chose, on
// for Apple Silicon (unified memory) and off elsewhere — a decode on an Intel CPU is 10x slower and is the thing
// a dictation can wait behind.
//
// A settings file that cannot be read keeps captions OFF: the default would silently undo an opt-out stored in the
// very file that cannot be read. It is logged once, without content, as the retention sweep does.
func (d *Daemon) liveEnabled() bool {
	st, err := d.Meet.Store.LoadSettings()
	if err != nil {
		if d.live != nil && !d.live.settingsWarned.Swap(true) {
			d.log.Warn("meeting: live captions are off, the settings file is unusable", slog.Any("error", err))
		}
		return false
	}
	if d.live != nil {
		d.live.settingsWarned.Store(false)
	}
	if st.LiveCaptions != nil {
		return *st.LiveCaptions
	}
	return d.liveDefault()
}

func (d *Daemon) liveDefault() bool { return d.Cfg.UnifiedMemory() }

// liveHold is the worker's Hold: why a caption may not be decoded right now, "" when it may.
func (d *Daemon) liveHold() string {
	if d.inflight.Load() > 0 ||
		time.Since(time.Unix(0, d.lastInteractiveEnd.Load())) < interactiveQuiet ||
		d.sttSessions() > 0 {
		return "dictation"
	}
	if lvl := memoryPressureLevel(); lvl >= livePressureHold {
		return "memory"
	}
	if d.liveLowPower() {
		return "power"
	}
	return ""
}

// liveLowPower is Low Power Mode, read at most every livePowerTTL. On battery alone captions keep running: they
// are about 1% duty on Apple Silicon, and pausing on any battery would end them on a laptop call.
func (d *Daemon) liveLowPower() bool {
	m := d.live
	m.powerMu.Lock() // its own lock: pmset is a subprocess, and m.mu is taken by starting a recording
	defer m.powerMu.Unlock()
	if time.Since(m.powerAt) >= livePowerTTL {
		_, m.lowPower = powerState(context.Background())
		m.powerAt = time.Now()
	}
	return m.lowPower
}

// liveDecode recognizes one chunk on the resident server, with the glossary's boost list like dictation.
// liveDecodeTimeout bounds one caption's decode: a wedged speech server must not hold the worker, the decode lock
// and the supervisor's guard for ever. A var so a test can shorten it.
var liveDecodeTimeout = 30 * time.Second

func (d *Daemon) liveDecode(ctx context.Context, wav []byte) (string, error) {
	if d.STTSup == nil {
		return "", errors.New("the speech server is off")
	}
	server := d.sttServer
	if d.live != nil && d.live.server != nil {
		server = d.live.server
	}
	dctx, cancel := context.WithTimeout(ctx, liveDecodeTimeout)
	defer cancel()
	opts := stt.Options{Boost: d.sttBoost(), Server: server}
	res, err := stt.TranscribeWAVViaServer(dctx, wav, opts)
	var rej *stt.ServerRejection
	if errors.As(err, &rej) {
		return "", fmt.Errorf("%w: %v", meeting.ErrLiveRejected, err)
	}
	if err != nil && ctx.Err() == nil && dctx.Err() != nil {
		// The deadline of ours: the server took this chunk and never answered. Counted as a refusal, so a chunk that
		// wedges it is given up after a few tries and the captions move on.
		return "", fmt.Errorf("%w: no answer within %s", meeting.ErrLiveRejected, liveDecodeTimeout)
	}
	if err != nil {
		return "", err
	}
	return res.Text, nil
}

// liveManager holds the running workers, one per recording meeting.
type liveManager struct {
	d       *Daemon
	mu      sync.Mutex
	workers map[string]*liveEntry
	closed  bool
	wg      sync.WaitGroup
	// decode is the recognizer of the workers; nil is liveDecode (a test puts a fake here).
	decode func(context.Context, []byte) (string, error)
	// server is the speech server of the decode; nil is d.sttServer (a test puts a fake here).
	server func(context.Context) (string, func(), error)
	// settingsWarned: the unusable-settings warning of liveEnabled was logged and has not been cured since.
	settingsWarned atomic.Bool
	// decodeMu is the one decode in flight across every recording (decoder).
	decodeMu sync.Mutex
	// lowPower and powerAt cache the Low Power Mode read (liveLowPower), under powerMu.
	powerMu  sync.Mutex
	lowPower bool
	powerAt  time.Time
}

type liveEntry struct {
	w      *meeting.LiveWorker
	cancel context.CancelFunc
}

// decoder is the Decode of every worker: one decode at a time across all recordings (two calls recording at once
// must not queue two captions on the server ahead of a dictation), and the hold asked again once this one has the
// turn — a worker that waited for another's decode would otherwise decode on a hold it never saw.
func (m *liveManager) decoder() func(context.Context, []byte) (string, error) {
	decode := m.decode
	if decode == nil {
		decode = m.d.liveDecode
	}
	return func(ctx context.Context, wav []byte) (string, error) {
		m.decodeMu.Lock()
		defer m.decodeMu.Unlock()
		if m.d.liveHold() != "" {
			return "", meeting.ErrLiveHeld
		}
		return decode(ctx, wav)
	}
}

func newLiveManager(d *Daemon) *liveManager {
	return &liveManager{d: d, workers: map[string]*liveEntry{}}
}

// ensure starts the worker of a meeting that is recording, when live captions are on. Calling it again, for a
// meeting that is not recording or when they are off, does nothing.
func (m *liveManager) ensure(id string) {
	if m == nil || !m.d.liveEnabled() {
		return
	}
	d := m.d
	mf, err := d.Meet.Store.Load(id)
	if err != nil || mf.Status != meeting.StatusRecording {
		return
	}
	dir, err := d.Meet.Store.Dir(id)
	if err != nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.workers[id] != nil {
		return
	}
	w, err := meeting.NewLiveWorker(meeting.LiveDeps{
		Dir: dir,
		Recording: func() bool {
			cur, err := d.Meet.Store.Load(id)
			// a read that failed for another reason than "gone" says nothing about the recording: keep going
			return err == nil && cur.Status == meeting.StatusRecording || err != nil && !errors.Is(err, meeting.ErrNotFound)
		},
		Hold:    d.liveHold,
		Decode:  m.decoder(),
		Correct: func(s string) string { return d.corrector()(s) }, // pairs are cached by file mtime: a pair filed mid-call applies
		Log:     d.log,
	})
	if err != nil {
		d.log.Warn("meeting: live captions did not start", slog.Any("error", err))
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	e := &liveEntry{w: w, cancel: cancel}
	m.workers[id] = e
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		w.Run(ctx)
		m.mu.Lock()
		if m.workers[id] == e {
			delete(m.workers, id)
		}
		m.mu.Unlock()
		cancel()
	}()
}

// reconcile starts the workers of every recording meeting when live captions are on and stops them all when they
// are off: it is how a settings change and a daemon restart in the middle of a call take effect.
func (m *liveManager) reconcile() {
	if m == nil {
		return
	}
	if !m.d.liveEnabled() {
		m.mu.Lock()
		for id, e := range m.workers {
			e.cancel()
			// gone from the map now, not when its goroutine notices: a quick switch back on must start a worker
			delete(m.workers, id)
		}
		m.mu.Unlock()
		return
	}
	list, err := m.d.Meet.Store.List()
	if err != nil {
		return
	}
	for _, mf := range list {
		if mf.Status == meeting.StatusRecording {
			m.ensure(mf.ID)
		}
	}
}

// stopAll ends every worker and waits for them; none starts afterwards.
func (m *liveManager) stopAll() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.closed = true
	for _, e := range m.workers {
		e.cancel()
	}
	m.mu.Unlock()
	m.wg.Wait()
}

func (m *liveManager) state(id string) (meeting.LiveState, bool) {
	if m == nil {
		return meeting.LiveState{}, false
	}
	m.mu.Lock()
	e := m.workers[id]
	m.mu.Unlock()
	if e == nil {
		return meeting.LiveState{}, false
	}
	return e.w.State(), true
}

// liveState is the "state" of a live answer.
type liveState struct {
	// Enabled: live captions are on in the settings.
	Enabled bool `json:"enabled"`
	// Recording: the meeting is still being recorded.
	Recording bool `json:"recording"`
	// Active: a worker is captioning it now.
	Active bool `json:"active"`
	// Lagging: the captions are behind, held or cannot reach the recognizer; the app says "live text is behind".
	Lagging bool `json:"lagging"`
	// Paused is why a caption was held the last time: dictation, memory or power.
	Paused  string  `json:"paused,omitempty"`
	BehindS float64 `json:"behind_s,omitempty"`
	// Problem is "recognizer" or "disk" while the worker cannot do its job.
	Problem string `json:"problem,omitempty"`
}

// liveAnswer is GET /v1/meetings/{id}/live.
type liveAnswer struct {
	ID       string                `json:"id"`
	Segments []meeting.LiveSegment `json:"segments"`
	// Next is the cursor: ask again with after=Next.
	Next  int       `json:"next"`
	State liveState `json:"state"`
}

const (
	liveDefaultLimit = 500
	liveMaxLimit     = 1000
)

// Live is the captions of a meeting after the cursor, with the worker's state. It is the one read the HTTP route
// and a later MCP tool share.
func (d *Daemon) Live(id string, after, limit int) (liveAnswer, error) {
	mf, err := d.Meet.Store.Load(id)
	if err != nil {
		return liveAnswer{}, err
	}
	dir, err := d.Meet.Store.Dir(id)
	if err != nil {
		return liveAnswer{}, err
	}
	segs, next, err := meeting.ReadLive(dir, after, limit)
	if err != nil {
		return liveAnswer{}, err
	}
	st, active := d.live.state(id)
	return liveAnswer{ID: id, Segments: segs, Next: next, State: liveState{
		Enabled:   d.liveEnabled(),
		Recording: mf.Status == meeting.StatusRecording,
		Active:    active,
		Lagging:   active && st.Lagging(),
		Paused:    st.Paused,
		BehindS:   float64(int(st.BehindS*10)) / 10,
		Problem:   st.Problem,
	}}, nil
}

// handleMeetingLive is GET /v1/meetings/{id}/live?after=<seq>&limit=<n>: the captions with a Seq above after, oldest
// first, and the cursor for the next poll. The text is the user's own speech: the route is read-only behind Guard
// like the other meeting reads, and the caption text is never logged.
func (d *Daemon) handleMeetingLive(w http.ResponseWriter, r *http.Request) {
	after, limit := 0, liveDefaultLimit
	if v := r.URL.Query().Get("after"); v != "" {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil || n < 0 {
			writeErr(w, http.StatusBadRequest, "after must be a whole number, 0 or more")
			return
		}
		after = n
	}
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil || n < 1 {
			writeErr(w, http.StatusBadRequest, "limit must be a whole number, 1 or more")
			return
		}
		limit = min(n, liveMaxLimit)
	}
	out, err := d.Live(r.PathValue("id"), after, limit)
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store") // a call's text is not for a cache
	writeJSON(w, http.StatusOK, out)
}
