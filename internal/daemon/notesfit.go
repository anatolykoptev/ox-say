package daemon

// The notes engine's start-time GPU fit check and the OOM retry it feeds.
//
// On Apple Silicon the notes model shares the Metal wired budget with the
// rest of the machine — the resident STT, the window server, whatever else
// is open. The measured evidence (the emulated 16 GB run) peaked ~300 MiB
// under the limit, so a model that fits in theory can still fail to load in
// practice, and a failed start used to mean no notes. The check runs inside
// the supervisor's per-spawn argv (notesEngineConfig's Args): before every
// spawn it reads the budget actually free right now — the wired limit minus
// what is already allocated — and decides the spawn's offload:
//
//   - fits with the safety margin → the ordinary full offload;
//   - does not → partial offload: -ngl reduced to the layer count the free
//     budget still carries;
//   - even that does not fit → the compact model, for an automatic choice
//     only, and only when its file is installed (never a download during a
//     meeting);
//   - a saved or env choice is never swapped for another model: it gets
//     partial offload, and a spawn that still fails OOM gets one retry and
//     then an honest failure reason.
//
// A spawn that fails with an out-of-memory line in its log — the estimate
// was wrong, not just tight — escalates the degradation floor for the next
// spawn: once to partial offload, then (automatic choices with the compact
// model installed) to the 4B. The floor is keyed to the resolved model and
// lifts when the resolution changes; it does not trust the estimate again
// because the OOM already proved it wrong for this file.

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"sync"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

const (
	// fitPartial and fitFallback are the values /status reports in notes.fit
	// when a spawn did not run the resolved model at full offload.
	fitPartial  = "partial_offload"
	fitFallback = "fallback_4b"

	// notesFitHeadroom stays free while the model loads: the system shares
	// the wired budget — the spike peaked ~300 MiB under the limit — and an
	// estimate that lands the engine exactly on the limit still OOMs.
	notesFitHeadroom = 1 << 30
	// notesComputeBytes is the fixed GPU-side cost beside weights and KV:
	// compute buffers, the hybrid layers' recurrent state, the output side.
	// Conservative next to what llama.cpp allocates for this arch.
	notesComputeBytes = 1 << 30
	// notesKVPerToken stands in when the file's own metadata cannot be
	// read: 48 KiB of f16 KV per context token — an all-attention bound for
	// the catalog models (the hybrid's real figure is smaller).
	notesKVPerToken = 48 << 10
	// notesFallbackLayers stands in when the file's block_count cannot be
	// read — a mid-size catalog model's layer count.
	notesFallbackLayers = 32
	// notesMinPartialLayers is the smallest offload still worth its name:
	// below it the GPU share is a sliver and an automatic choice should run
	// the compact model instead of pretending to offload.
	notesMinPartialLayers = 4
)

// notesGPUWired reports the Metal wired limit and the bytes already
// allocated system-wide for the ox-llm binary at bin. On Darwin the limit is
// iogpu.wired_limit_mb when set, else the Metal total ox-llm --list-devices
// prints (read once per process, in the background); the used figure is the
// IOAccelerator "Alloc system memory" from ioreg (notesfit_probe.go). It
// reports (0,0) elsewhere — and tests replace it. A zero limit means unknown
// and the check is skipped entirely: the same "unknown never blocks"
// convention as the other memory gates.
var notesGPUWired = defaultNotesGPUWired

// notesGPUWarmup starts the one background Metal-total read at daemon start
// (a no-op off Darwin); tests replace it so the fake ox-llm is not exec'd.
var notesGPUWarmup = notesGPUWarm

// notesGPUFree is the GPU budget actually free right now: the wired limit
// minus what is already allocated, and whether the probe knew the numbers.
func notesGPUFree(bin string) (free int64, known bool) {
	limit, used := notesGPUWired(bin)
	if limit == 0 {
		return 0, false
	}
	if used >= limit {
		return 0, true
	}
	return int64(limit - used), true
}

// notesPlan is one spawn's fit decision: which model file the argv names
// and at which offload. ngl "" is the config's default (notesGPULayers);
// fit and why feed /status and the log.
type notesPlan struct {
	model string
	ngl   string
	fit   string
	why   string
}

// notesFit is the daemon's record of the fit decisions: the degradation
// floor an OOM'd start forced and the label /status reports for the spawn
// argv last built.
type notesFit struct {
	mu sync.Mutex
	// esc is the forced degradation floor: 1 — partial offload, 2 — the
	// compact model. escPath keys it to the resolution it was proved
	// against; a different resolution decides fresh.
	esc     int
	escPath string
	fit     string
	why     string
}

// notesModelNeed estimates the GPU bytes the resolution's full offload
// wants: the weights (the catalog pin, or the custom file's own size), the
// context's KV cache, and the fixed compute side. It also returns the share
// one transformer layer carries — what each layer a reduced -ngl leaves on
// the CPU saves — and the layer count.
func notesModelNeed(res config.NotesResolution) (need, perLayer, layers int64) {
	var size int64
	switch {
	case res.Entry != nil:
		size = res.Entry.Bytes
	case res.Installed:
		size, _ = fileSize(res.Path)
	}
	layers, kvPerToken := int64(notesFallbackLayers), int64(notesKVPerToken)
	if meta, err := ggufReadMeta(res.Path); err == nil {
		if meta.Layers > 0 {
			layers = int64(meta.Layers)
		}
		if meta.KVHeads > 0 && meta.HeadDim > 0 {
			// f16 K and V per token per layer. The hybrid arch's recurrent
			// layers take this all-attention figure too — overestimating is
			// the safe direction for a fit check, and their real (fixed)
			// state is part of notesComputeBytes.
			kvPerToken = int64(meta.KVHeads) * int64(meta.HeadDim) * 4 * layers
		}
	}
	movable := size + int64(meeting.NotesContextTokens())*kvPerToken
	return movable + notesComputeBytes, movable / layers, layers
}

// notesFitLayers is the layer count the free budget still carries next to
// the fixed compute side and the safety margin. 0 means even a sliver does
// not fit.
func notesFitLayers(perLayer, layers, free int64) int {
	movable := free - notesFitHeadroom - notesComputeBytes
	if movable <= 0 || perLayer <= 0 {
		return 0
	}
	n := movable / perLayer
	if n >= layers {
		return int(layers)
	}
	return int(n)
}

// notesSpawnPlan decides the argv the next spawn gets. Called inside the
// supervisor's Args func, so it re-reads the resolution and the free budget
// at every start; it also records the decision /status reports.
func (d *Daemon) notesSpawnPlan() notesPlan {
	res := d.notesResolve()
	p := notesPlan{model: res.Path}
	if p.model == "" {
		p.model = d.Cfg.NotesModel
	}
	if !d.Cfg.UnifiedMemory() || !res.Installed {
		return p // CPU decode decides nothing; a missing model fails as before
	}
	free, known := notesGPUFree(notesBinPath(d.Cfg))
	if !known {
		return p
	}
	need, perLayer, layers := notesModelNeed(res)
	lvl := 0
	if need+notesFitHeadroom > free {
		lvl = 1
	}
	if esc := d.fitEscalation(res); esc > lvl {
		lvl = esc
	}
	if lvl == 0 {
		return d.recordPlan(p)
	}
	// Partial offload: the most layers the free budget still carries —
	// capped one short of all of them, so "partial" always offloads less
	// than the full spawn that was just measured or just failed.
	if lvl < 2 {
		if n := min(notesFitLayers(perLayer, layers, free), int(layers)-1); n > 0 {
			if n >= notesMinPartialLayers || res.Source != config.NotesSourceAutomatic {
				return d.recordPlan(notesPlan{
					model: res.Path, ngl: strconv.Itoa(n), fit: fitPartial,
					why: fmt.Sprintf("the model's estimated %s plus the safety margin exceeds the %s of GPU memory free; %d of %d layers run on the GPU",
						notesGB(need), notesGB(free), n, layers),
				})
			}
		}
	}
	// The compact model is the floor for an automatic choice only — a
	// saved or env pick is the user's own and is never swapped.
	if res.Source == config.NotesSourceAutomatic {
		if cp, ok := d.compactFitPlan(res, free); ok {
			return d.recordPlan(cp)
		}
	}
	// Nothing fits: an explicit choice, or an automatic one whose compact
	// model is absent, still tries the thinnest offload — the estimate is
	// conservative, and a real OOM gets the retry's say.
	return d.recordPlan(notesPlan{
		model: res.Path, ngl: "1", fit: fitPartial,
		why: fmt.Sprintf("the model's estimated %s exceeds the %s of GPU memory free even layer by layer; trying the thinnest offload", notesGB(need), notesGB(free)),
	})
}

// compactFitPlan is the fallback_4b rung: the catalog's compact entry,
// installed (never downloaded mid-meeting), fully or partially offloaded
// into the same free budget. ok is false when the compact model is the
// resolved one already, is not installed, or does not fit either.
func (d *Daemon) compactFitPlan(res config.NotesResolution, free int64) (notesPlan, bool) {
	e := notesCompactEntry()
	if e == nil || (res.Entry != nil && res.Entry.ID == e.ID) {
		return notesPlan{}, false
	}
	path := filepath.Join(d.Cfg.ModelsDir(), e.File)
	if !notesInstalled(path) {
		return notesPlan{}, false
	}
	cres := config.NotesResolution{Source: res.Source, ID: e.ID, Path: path, Entry: e, Installed: true}
	need, perLayer, layers := notesModelNeed(cres)
	p := notesPlan{
		model: path, fit: fitFallback,
		why: fmt.Sprintf("the resolved model does not fit the %s of GPU memory free; the compact %s is installed and writes this meeting's notes",
			notesGB(free), e.Name),
	}
	if need+notesFitHeadroom > free {
		if n := min(notesFitLayers(perLayer, layers, free), int(layers)-1); n > 0 {
			p.ngl = strconv.Itoa(n)
		} else {
			return notesPlan{}, false
		}
	}
	return p, true
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
// model: an automatic resolution of a different entry while the compact
// file is installed.
func (d *Daemon) compactSwappable(res config.NotesResolution) bool {
	e := notesCompactEntry()
	return res.Source == config.NotesSourceAutomatic && e != nil &&
		(res.Entry == nil || res.Entry.ID != e.ID) &&
		notesInstalled(filepath.Join(d.Cfg.ModelsDir(), e.File))
}

// fitEscalation is the degradation floor the OOM retry set for this
// resolution; 0 when none is set or the resolved model changed since.
func (d *Daemon) fitEscalation(res config.NotesResolution) int {
	d.fit.mu.Lock()
	defer d.fit.mu.Unlock()
	if d.fit.esc != 0 && d.fit.escPath != res.Path {
		d.fit.esc = 0
	}
	return d.fit.esc
}

// notesEscalate raises the degradation floor after a start that failed with
// an OOM line: once to partial offload for any resolution, once more to the
// compact model for an automatic choice that has one installed. It reports
// whether a new floor was set — false means the ladder is spent and the
// failure is real.
func (d *Daemon) notesEscalate() bool {
	res := d.notesResolve()
	ceiling := 1
	if d.compactSwappable(res) {
		ceiling = 2
	}
	d.fit.mu.Lock()
	defer d.fit.mu.Unlock()
	if d.fit.esc >= ceiling {
		return false
	}
	d.fit.esc++
	d.fit.escPath = res.Path
	return true
}

// recordPlan stores the decision /status reports and logs a degraded one
// once per change. A full-offload plan clears the label.
func (d *Daemon) recordPlan(p notesPlan) notesPlan {
	d.fit.mu.Lock()
	changed := d.fit.fit != p.fit || d.fit.why != p.why
	d.fit.fit, d.fit.why = p.fit, p.why
	d.fit.mu.Unlock()
	if p.fit != "" && changed {
		d.log.Info("the notes model does not fit the free GPU memory; starting degraded",
			slog.String("fit", p.fit), slog.String("reason", p.why),
			slog.String("model", filepath.Base(p.model)), slog.String("ngl", p.ngl))
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

// notesStartOOMed reports whether the child spawned since mark left an
// out-of-memory line in its log.
func (d *Daemon) notesStartOOMed(mark int64) bool {
	f, err := os.Open(filepath.Join(d.Cfg.EngineLogDir, "notes.log"))
	if err != nil {
		return false
	}
	defer f.Close()
	if _, err := f.Seek(mark, io.SeekStart); err != nil {
		return false
	}
	tail, err := io.ReadAll(io.LimitReader(f, 256<<10))
	if err != nil {
		return false
	}
	low := bytes.ToLower(tail)
	for _, sig := range notesOOMSignatures {
		if bytes.Contains(low, []byte(sig)) {
			return true
		}
	}
	return false
}

// notesGB renders a byte count in the reason strings.
func notesGB(n int64) string {
	return fmt.Sprintf("%.1f GB", float64(n)/1e9)
}
