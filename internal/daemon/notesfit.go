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
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
)

const (
	// The values /status reports in notes.fit.
	fitFull      = "full"        // the plan is a full-offload fit
	fitFitted    = "fitted"      // llama.cpp fitted fewer layers, or the target was raised after an OOM
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
		p.why = fmt.Sprintf("the GPU budget could not be read; llama.cpp fits the model with its default %d MiB margin", target)
	case esc > 0:
		p.fit = fitFitted
		p.why = fmt.Sprintf("an earlier start ran out of memory; the fit margin is raised to %d MiB", target)
	default:
		p.fit = fitFull
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
	return d.finishPlan(res, p)
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

// offloadedRe is the loader's own line for what the fitter decided:
// "load_tensors: offloaded 16/33 layers to GPU" (printed at -lv 4).
var offloadedRe = regexp.MustCompile(`load_tensors: offloaded (\d+)/(\d+) layers to GPU`)

// parseOffloaded returns the last offloaded-layers line of a child log.
func parseOffloaded(log []byte) (on, total int, ok bool) {
	all := offloadedRe.FindAllSubmatch(log, -1)
	if len(all) == 0 {
		return 0, 0, false
	}
	m := all[len(all)-1]
	on, e1 := strconv.Atoi(string(m[1]))
	total, e2 := strconv.Atoi(string(m[2]))
	return on, total, e1 == nil && e2 == nil && total > 0
}

// notesNoteOffload folds what llama.cpp chose into /status after a start:
// fewer layers than the model has means the fitter trimmed it.
func (d *Daemon) notesNoteOffload(mark int64) {
	on, total, ok := parseOffloaded(d.notesLogSince(mark))
	if !ok || on >= total {
		return
	}
	d.fit.mu.Lock()
	defer d.fit.mu.Unlock()
	if d.fit.fit == "" {
		return // CPU decode (-ngl 0): no fitter ran, "0 layers" is the plan
	}
	if d.fit.fit == fitFull || d.fit.fit == fitUnchecked {
		d.fit.fit = fitFitted
		d.fit.why = ""
	}
	if d.fit.why != "" {
		d.fit.why += "; "
	}
	d.fit.why += fmt.Sprintf("llama.cpp fitted %d of %d layers onto the GPU", on, total)
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
