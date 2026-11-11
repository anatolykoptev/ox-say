package daemon

// The notes engine's start-time GPU fit and the OOM retry it feeds.
//
// On Apple Silicon the notes model shares the Metal wired budget with the
// rest of the machine — the resident STT, the window server, the browser in
// the call. llama.cpp (the pinned ox-llm) already carries a per-tensor
// fitter, on by default: with -ngl left unset it measures the real weights,
// the KV cache at the requested type and the recurrent state of the hybrid
// layers, and offloads as many layers as leave --fit-target MiB free. What
// it cannot see is the other processes' share: on Metal its "free" figure is
// the wired limit minus its OWN allocations. This file supplies exactly that
// missing figure — the system-wide IOAccelerator "Alloc system memory" read
// right before the spawn (our previous child is gone by then, so it does not
// count us) — as the fitter's target, plus a headroom for the call.
//
// So the spawn's argv is: no -ngl, an explicit -c (the fitter changes only
// the layer count, never the context), --fit on --fit-target <others' use +
// headroom>. There is no layer arithmetic of our own: an estimate of ours
// was the thing an OOM proved wrong, and the retry reused it.
//
// One coarse check stays, for an automatic choice only and only when the 4B
// file is installed: when the resolved model's WEIGHTS alone exceed the
// budget left after the others and the headroom, the spawn runs the 4B
// instead (never a download during a meeting). A saved or env choice is
// never swapped.
//
// A start that fails with an out-of-memory line in its log (the others
// allocated between the read and the load, or the budget was wrong) raises
// the floor: first the same model with --fit-target 2 GiB higher, then — an
// automatic choice with the 4B installed — the 4B; any other choice fails
// with an honest reason. The floor holds for notesFloorTTL and ends with the
// next meeting's notes job, so one browser spike does not pin the 4B until
// the daemon restarts. It applies even when the budget probe is unknown.

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
)

const (
	// The values /status reports in notes.fit.
	fitFull      = "full"        // the plan is a full-offload fit
	fitPartial   = "partial"     // the weights exceed the room left: llama.cpp keeps part of the model on the CPU
	fitFitted    = "fitted"      // an OOM raised the fit target
	fitFallback  = "fallback_4b" // the automatic choice was swapped for the installed 4B
	fitUnchecked = "unchecked"   // the budget probe is unknown; llama.cpp fitted with its default margin

	// notesFitHeadroomMiB stays free on top of what the others hold: the
	// owner requires room for the browser in the call.
	notesFitHeadroomMiB = 1536
	// notesFitDefaultTargetMiB is llama.cpp's own --fit-target default, used
	// when the others' share is unknown.
	notesFitDefaultTargetMiB = 1024
	// notesFitOOMStepMiB is how much an OOM'd start raises the target.
	notesFitOOMStepMiB = 2048
	// notesFloorTTL is how long an OOM floor holds without a new OOM.
	notesFloorTTL = 10 * time.Minute
	// notesOOMScanTail bounds the child-log bytes the OOM scan reads.
	notesOOMScanTail = 256 << 10
)

// notesGPUWired reports the Metal wired limit and the bytes already
// allocated system-wide for the ox-llm binary at bin, in bytes. On Darwin
// the limit is iogpu.wired_limit_mb when set, else the Metal total ox-llm
// --list-devices prints (read in the background, retried at a spawn while it
// is unknown); the used figure is the IOAccelerator "Alloc system memory"
// from ioreg (notesfit_probe.go). It reports (0,0) elsewhere — and tests
// replace it. A zero limit means unknown: llama.cpp then fits with its
// default margin and /status says "unchecked".
var notesGPUWired = defaultNotesGPUWired

// notesGPUWarmup starts the background Metal-total read at daemon start (a
// no-op off Darwin); tests replace it so the fake ox-llm is not exec'd.
var notesGPUWarmup = notesGPUWarm

// notesPlan is one spawn's decision: which model file the argv names and the
// --fit-target MiB (0: no fitter, the config's default -ngl). fit and why
// feed /status and the log.
type notesPlan struct {
	model  string
	fitMiB int
	fit    string
	why    string
}

// notesSpawn is what the last spawn was planned for: the resolution's model
// path and the model the argv named. The stale check compares the CURRENT
// resolution with it — never a fresh plan, which would count the resident
// child's own GPU allocation as somebody else's.
type notesSpawn struct {
	set     bool
	resPath string
	model   string
}

// notesFit is the daemon's record of the fit decisions: the OOM floor, the
// last spawn and the label /status reports for it.
type notesFit struct {
	mu sync.Mutex
	// esc is the OOM floor: 1 — the target raised, 2 — the compact model.
	// escPath keys it to the resolution it was proved against and escAt
	// stamps the last OOM; a different resolution, the TTL or the next
	// meeting's notes job ends it.
	esc     int
	escPath string
	escAt   time.Time
	spawn   notesSpawn
	fit     string
	why     string
	// now is the clock; tests inject it.
	now func() time.Time
}

func (f *notesFit) clock() time.Time {
	if f.now != nil {
		return f.now()
	}
	return time.Now()
}

// notesWeightBytes is the resolution's weight bytes: the catalog pin, or the
// custom file's own size. 0 when unknown.
func notesWeightBytes(res config.NotesResolution) int64 {
	if res.Entry != nil {
		return res.Entry.Bytes
	}
	if n, ok := fileSize(res.Path); ok {
		return n
	}
	return 0
}

// notesSpawnPlan decides the argv the next spawn gets. Called inside the
// supervisor's Args func, so it re-reads the resolution and the budget at
// every start and records the decision /status reports — every return path
// goes through finishPlan, so the label never outlives its spawn.
func (d *Daemon) notesSpawnPlan() notesPlan {
	res := d.notesResolve()
	p := notesPlan{model: res.Path}
	if p.model == "" {
		p.model = d.Cfg.NotesModel
	}
	if !d.Cfg.UnifiedMemory() || !res.Installed {
		return d.finishPlan(res, p) // CPU decode decides nothing; a missing model fails as before
	}
	esc := d.fitEscalation(res)
	limit, used := notesGPUWired(notesBinPath(d.Cfg))
	known := limit > 0
	target := notesFitDefaultTargetMiB
	if known {
		target = int(used>>20) + notesFitHeadroomMiB
	}
	if esc > 0 {
		target += notesFitOOMStepMiB
	}
	p.fitMiB = target
	switch {
	case !known:
		p.fit = fitUnchecked
		p.why = fmt.Sprintf("the GPU budget could not be read; llama.cpp fits the model with --fit-target %d MiB", target)
	case esc > 0:
		p.fit = fitFitted
		p.why = fmt.Sprintf("an earlier start ran out of memory; llama.cpp fits the model with --fit-target raised to %d MiB", target)
	default:
		p.fit = fitFull
		p.why = fmt.Sprintf("llama.cpp fits the model with --fit-target %d MiB: the rest of the system's GPU memory plus %d MiB of headroom", target, notesFitHeadroomMiB)
	}
	if res.Source == config.NotesSourceAutomatic {
		swap, why := esc >= 2, "an earlier start of the resolved model ran out of memory twice"
		if !swap && known {
			free := int64(limit) - int64(used) - int64(notesFitHeadroomMiB)<<20
			if w := notesWeightBytes(res); w > 0 && w > free {
				swap = true
				why = fmt.Sprintf("the resolved model's weights (%s) exceed the %s of GPU memory left after the rest of the system and the call's headroom",
					notesGiB(w), notesGiB(max(free, 0)))
			}
		}
		if swap {
			if path, ok := d.compactInstalled(res); ok {
				p.model, p.fit = path, fitFallback
				p.why = why + "; the compact model is installed and writes this meeting's notes"
			}
		}
	}
	if known && p.fit == fitFull {
		if free := notesRoomBytes(limit, used); notesWeightBytes(res) > free {
			p.fit = fitPartial
			p.why = fmt.Sprintf("the model's weights (%s) exceed the %s of GPU memory left after the rest of the system (%s) and the call's headroom; llama.cpp keeps part of the model on the CPU, so notes are slower",
				notesGiB(notesWeightBytes(res)), notesGiB(max(free, 0)), notesGiB(int64(used)))
		}
	}
	return d.finishPlan(res, p)
}

// notesRoomBytes is the GPU memory left for the notes model: the wired limit minus what the rest of the system
// holds minus the call's headroom. Negative when the others already take more.
func notesRoomBytes(limit, used uint64) int64 {
	return int64(limit) - int64(used) - int64(notesFitHeadroomMiB)<<20
}

// notesRoomSlack is how much room beyond the weights makeNotesRoom wants before it leaves the voices alone: the
// KV cache and the compute buffers.
const notesRoomSlack = 1 << 30

// makeNotesRoom runs before a meeting's notes engine is spawned. In shared mode (no arbiter turn) the idle voices
// stay resident, and on a small Mac they leave the model less room than its weights; llama.cpp then keeps layers on
// the CPU and the notes run at a fraction of the speed (gate, 24 GB tier: 28 tok/s against 70). When the probe is
// known and the room is under weights + notesRoomSlack, the fast and the studio voice are stopped if they are idle.
// A voice that is rendering is never stopped (the spawn goes ahead and the fitter copes); a stopped voice starts
// again on its next request, as after its own idle stop. The spawn that follows plans from a fresh probe.
func (d *Daemon) makeNotesRoom(ctx context.Context) {
	if d.LLMSup == nil || !d.Cfg.UnifiedMemory() || d.mem.managed(d.LLMSup) {
		return // the arbiter makes the room by its own turn change
	}
	if _, live := d.LLMSup.LiveURL(); live {
		return // already spawned: later chunks of the same job
	}
	res := d.notesResolve()
	w := notesWeightBytes(res)
	if !res.Installed || w <= 0 {
		return
	}
	bin := notesBinPath(d.Cfg)
	limit, used := notesGPUWired(bin)
	if limit == 0 {
		return
	}
	before := notesRoomBytes(limit, used)
	if before >= w+notesRoomSlack {
		return
	}
	var stopped []string
	for _, v := range []*engine.Supervisor{d.Sup, d.VoxSup} {
		if v == nil || !v.Idle() {
			continue
		}
		sctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		err := d.mem.stopEngine(sctx, v)
		cancel()
		if err != nil {
			d.log.Warn("notes: could not stop an idle voice to make room", slog.String("engine", v.Name()), slog.Any("error", err))
			continue
		}
		stopped = append(stopped, v.Name())
	}
	if len(stopped) == 0 {
		return
	}
	_, usedAfter := notesGPUWired(bin)
	d.log.Info("notes: stopped idle voices to make room for the notes model",
		slog.Any("stopped", stopped), slog.String("weights", notesGiB(w)),
		slog.String("room_before", notesGiB(max(before, 0))), slog.String("room_after", notesGiB(max(notesRoomBytes(limit, usedAfter), 0))))
}

// finishPlan records the spawn and the /status label of plan p.
func (d *Daemon) finishPlan(res config.NotesResolution, p notesPlan) notesPlan {
	d.fit.mu.Lock()
	d.fit.spawn = notesSpawn{set: true, resPath: res.Path, model: p.model}
	d.fit.mu.Unlock()
	return d.recordPlan(p)
}

// compactInstalled is the compact catalog model's path when it is installed
// (never downloaded mid-meeting) and is not the resolved model already.
func (d *Daemon) compactInstalled(res config.NotesResolution) (string, bool) {
	e := notesCompactEntry()
	if e == nil || (res.Entry != nil && res.Entry.ID == e.ID) {
		return "", false
	}
	path := filepath.Join(d.Cfg.ModelsDir(), e.File)
	return path, notesInstalled(path)
}

// notesCompactEntry is the catalog's compact row — the automatic choice's
// lighter fallback.
func notesCompactEntry() *config.NotesModelEntry {
	for i := range config.NotesCatalog {
		if config.NotesCatalog[i].Kind == config.NotesKindCompact {
			return &config.NotesCatalog[i]
		}
	}
	return nil
}

// compactSwappable reports whether the OOM retry may end on the compact
// model: an automatic resolution of a different entry while the compact file
// is installed.
func (d *Daemon) compactSwappable(res config.NotesResolution) bool {
	_, ok := d.compactInstalled(res)
	return res.Source == config.NotesSourceAutomatic && ok
}

// fitEscalation is the OOM floor for this resolution; 0 when none is set,
// the resolved model changed since, or the last OOM is older than the TTL.
func (d *Daemon) fitEscalation(res config.NotesResolution) int {
	d.fit.mu.Lock()
	defer d.fit.mu.Unlock()
	if d.fit.esc != 0 && (d.fit.escPath != res.Path || d.fit.clock().Sub(d.fit.escAt) >= notesFloorTTL) {
		d.fit.esc = 0
	}
	return d.fit.esc
}

// liftNotesFloor ends the OOM floor: a new meeting's notes job decides the
// budget afresh.
func (d *Daemon) liftNotesFloor() {
	d.fit.mu.Lock()
	d.fit.esc = 0
	d.fit.mu.Unlock()
}

// notesEscalate raises the OOM floor after a start that failed with an OOM
// line: once to a higher fit target for any resolution, once more to the
// compact model for an automatic choice that has one installed. It reports
// whether a new floor was set — false means the ladder is spent and the
// failure is real.
func (d *Daemon) notesEscalate() bool {
	res := d.notesResolve()
	ceiling := 1
	if d.compactSwappable(res) {
		ceiling = 2
	}
	// Read through fitEscalation first: an expired or foreign floor counts as 0.
	cur := d.fitEscalation(res)
	d.fit.mu.Lock()
	defer d.fit.mu.Unlock()
	if cur >= ceiling {
		return false
	}
	d.fit.esc = cur + 1
	d.fit.escPath = res.Path
	d.fit.escAt = d.fit.clock()
	return true
}

// recordPlan stores the decision /status reports and logs a non-default one
// once per change. A full plan carries no reason.
func (d *Daemon) recordPlan(p notesPlan) notesPlan {
	d.fit.mu.Lock()
	changed := d.fit.fit != p.fit || d.fit.why != p.why
	d.fit.fit, d.fit.why = p.fit, p.why
	d.fit.mu.Unlock()
	if p.fit != "" && p.fit != fitFull && changed {
		d.log.Info("the notes engine starts with an adjusted GPU fit",
			slog.String("fit", p.fit), slog.String("reason", p.why),
			slog.String("model", filepath.Base(p.model)), slog.Int("fit_target_mib", p.fitMiB))
	}
	return p
}

// fitSnapshot is what /status reports.
func (d *Daemon) fitSnapshot() (fit, why string) {
	d.fit.mu.Lock()
	defer d.fit.mu.Unlock()
	return d.fit.fit, d.fit.why
}

// notesOOMSignatures are the words llama-server writes to stderr when the
// model load or the KV allocation runs out of memory — a Metal allocation
// failure, a full RAM — before /health ever answers. Matched lowercase.
var notesOOMSignatures = []string{
	"failed to allocate",  // ggml_metal_device_alloc: failed to allocate …
	"unable to allocate",  // llama_kv_cache_init: unable to allocate …
	"cannot allocate",     // ggml_backend_alloc_buffer: cannot allocate …
	"out of memory",       // ggml_backend_buffer … failed: out of memory
	"insufficient memory", // Metal/MTL reports
	"not enough memory",
}

// notesLogMark is the child log's size before a start attempt: the OOM
// check reads only the bytes the new child appended after it, so an older
// failure's line cannot masquerade as this one's.
func notesLogMark(logDir string) int64 {
	if st, err := os.Stat(filepath.Join(logDir, "notes.log")); err == nil {
		return st.Size()
	}
	return 0
}

// notesLogSince is the last notesOOMScanTail bytes of the child log written
// after mark. A mark past the end of the file means the supervisor truncated
// it (a log over its size cap restarts at 0): everything is new then.
func (d *Daemon) notesLogSince(mark int64) []byte {
	f, err := os.Open(filepath.Join(d.Cfg.EngineLogDir, "notes.log"))
	if err != nil {
		return nil
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil
	}
	start := mark
	if start < 0 || start > st.Size() {
		start = 0
	}
	if st.Size()-start > notesOOMScanTail {
		start = st.Size() - notesOOMScanTail
	}
	buf := make([]byte, st.Size()-start)
	n, err := f.ReadAt(buf, start)
	if err != nil && err != io.EOF {
		return nil
	}
	return buf[:n]
}

// notesStartOOMed reports whether the child spawned since mark left an
// out-of-memory line in its log.
func (d *Daemon) notesStartOOMed(mark int64) bool {
	low := bytes.ToLower(d.notesLogSince(mark))
	for _, sig := range notesOOMSignatures {
		if bytes.Contains(low, []byte(sig)) {
			return true
		}
	}
	return false
}

// notesGiB renders a byte count in the reason strings, in GiB like the MiB
// figures the probe reads.
func notesGiB(n int64) string {
	return fmt.Sprintf("%.1f GiB", float64(n)/(1<<30))
}
