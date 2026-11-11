package daemon

// The notes engine's start-time GPU fit (notesfit.go): the argv the spawn
// gets — llama.cpp's own fitter with a target that counts the rest of the
// system — the automatic-only swap onto the installed compact model, and the
// OOM retry with its floor. The GPU probe is replaced (notesGPUWired) and
// the fake ox-llm stamps every spawn's argv and can OOM a start on demand.

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

const mib = 1 << 20

// notesFitDaemon is a daemon on unified memory with the fake ox-llm and the
// named catalog files "installed" under <home>/models — the automatic
// resolution picks the standard 9B when its file is there.
func notesFitDaemon(t *testing.T, files ...string) (*Daemon, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
	d, _ := meetingFixture(t, func(c *config.Config) {
		c.GPUMemory = config.GPUMemoryUnified
		c.NotesBin = os.Args[0]
		for _, f := range files {
			p := filepath.Join(c.ModelsDir(), f)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	})
	t.Cleanup(d.Shutdown)
	return d, dir
}

// bothModels is the usual install: the standard 9B and the compact 4B.
func bothModels(t *testing.T) (*Daemon, string) {
	return notesFitDaemon(t, "Qwen3.5-9B-Q4_K_M.gguf", config.NotesModelFile)
}

// fakeBudget makes the GPU probe answer this wired limit and this much
// already allocated by the rest of the system, both in MiB.
func fakeBudget(t *testing.T, limitMiB, usedMiB uint64) {
	t.Helper()
	fakeBudgetFn(t, func() (uint64, uint64) { return limitMiB * mib, usedMiB * mib })
}

func fakeBudgetFn(t *testing.T, f func() (limit, used uint64)) {
	t.Helper()
	old := notesGPUWired
	notesGPUWired = func(string) (uint64, uint64) { return f() }
	t.Cleanup(func() { notesGPUWired = old })
}

// Budgets in MiB. The ample one: the 9B's 5.3 GiB of weights clear the 3 GiB
// held by the others and the 1.5 GiB headroom with ease.
const (
	ampleLimitMiB = 24 << 10
	othersMiB     = 3 << 10
	// tightLimitMiB leaves 8192-3072-1536 = 3584 MiB for weights: under the
	// 9B's 5418 MiB, over the 4B's.
	tightLimitMiB = 8 << 10
)

// spawnArgvs is every ox-llm spawn's argv, oldest first — the stamps are
// named by pid, so modtime orders them.
func spawnArgvs(t *testing.T, dir string) [][]string {
	t.Helper()
	marks := spawnStamps(t, dir)
	slices.SortFunc(marks, func(a, b string) int {
		ai, _ := os.Stat(a)
		aj, _ := os.Stat(b)
		return ai.ModTime().Compare(aj.ModTime())
	})
	out := make([][]string, 0, len(marks))
	for _, m := range marks {
		raw, err := os.ReadFile(m)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, strings.Split(strings.TrimSpace(string(raw)), "\n"))
	}
	return out
}

func fitTargetOf(t *testing.T, args []string) int {
	t.Helper()
	n, err := strconv.Atoi(notesFlagValue(args, "--fit-target"))
	if err != nil {
		t.Fatalf("no numeric --fit-target in %q", strings.Join(args, " "))
	}
	return n
}

func complete(t *testing.T, d *Daemon) error {
	t.Helper()
	_, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	return err
}

func modelOf(args []string) string { return filepath.Base(notesFlagValue(args, "-m")) }

// F1: the spawn hands the layer count to llama.cpp's fitter: no -ngl, the
// fitter on, a target of the rest of the system's allocation plus the
// headroom, and the context and the quantized KV exactly as derived.
// Mutation: internal/daemon/meetings.go notesPlanArgs — pass
// notesGPULayers(cfg) as ngl and fitMiB 0 -> RED (-ngl 99, no --fit-target).
func TestTheSpawnLetsLlamaCppFitTheModel(t *testing.T) {
	d, dir := bothModels(t)
	fakeBudget(t, ampleLimitMiB, othersMiB)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 {
		t.Fatalf("spawns = %d, want 1", len(args))
	}
	a := args[0]
	if slices.Contains(a, "-ngl") {
		t.Fatalf("argv carries -ngl, which disables llama.cpp's fitter: %q", strings.Join(a, " "))
	}
	if notesFlagValue(a, "--fit") != "on" {
		t.Fatalf("--fit = %q, want on", notesFlagValue(a, "--fit"))
	}
	if got, want := fitTargetOf(t, a), othersMiB+notesFitHeadroomMiB; got != want {
		t.Fatalf("--fit-target = %d, want the others' %d MiB plus the %d MiB headroom", got, othersMiB, notesFitHeadroomMiB)
	}
	if c := notesFlagValue(a, "-c"); c != strconv.Itoa(meeting.NotesContextTokens()) {
		t.Fatalf("-c = %q, want the derived %d", c, meeting.NotesContextTokens())
	}
	if notesFlagValue(a, "-ctk") != "q8_0" || notesFlagValue(a, "-ctv") != "q8_0" {
		t.Fatalf("the KV cache type changed: %q", strings.Join(a, " "))
	}
	if m := modelOf(a); !strings.Contains(m, "9B") {
		t.Fatalf("the spawn's model = %q, want the 9B", m)
	}
	if n := d.Status().Notes; n.Fit != "full" || !strings.Contains(n.FitReason, "--fit-target "+strconv.Itoa(othersMiB+notesFitHeadroomMiB)) {
		t.Fatalf("notes = %+v, want fit full with the fit target in its reason", n)
	}
}

// F2: the 9B's weights alone do not fit what the rest of the system and the
// headroom leave, the compact model is installed and the choice is
// automatic → the notes run on the 4B and say so.
// Mutation: internal/daemon/notesfit.go notesSpawnPlan — delete the swap
// branch (if swap) -> RED (the spawn keeps the 9B).
func TestNotesFallbackToTheCompactModel(t *testing.T) {
	d, dir := bothModels(t)
	fakeBudget(t, tightLimitMiB, othersMiB)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 {
		t.Fatalf("spawns = %d, want 1", len(args))
	}
	if m := modelOf(args[0]); !strings.Contains(m, "4B") {
		t.Fatalf("the spawn's model = %q, want the compact 4B", m)
	}
	if n := d.Status().Notes; n.Fit != "fallback_4b" || n.FitReason == "" {
		t.Fatalf("notes = %+v, want fit fallback_4b with its reason", n)
	}
}

// F3: the same budget, but the 9B is the user's SAVED choice — it is never
// swapped; llama.cpp's fitter trims it instead.
// Mutation: internal/daemon/notesfit.go notesSpawnPlan — drop the
// res.Source == config.NotesSourceAutomatic condition -> RED (the 4B runs).
func TestASavedChoiceIsNeverSwapped(t *testing.T) {
	d, dir := bothModels(t)
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	fakeBudget(t, tightLimitMiB, othersMiB)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 {
		t.Fatalf("spawns = %d, want 1", len(args))
	}
	if m := modelOf(args[0]); !strings.Contains(m, "9B") {
		t.Fatalf("a saved choice was swapped: the spawn's model = %q", m)
	}
	if !slices.Contains(args[0], "--fit-target") {
		t.Fatalf("the saved 9B got no fit target: %q", strings.Join(args[0], " "))
	}
	if n := d.Status().Notes; n.Fit == "fallback_4b" {
		t.Fatalf("notes = %+v — an explicit choice must never report fallback_4b", n)
	}
}

// F4/F2': the first OOM respawns the SAME model with the fit target 2 GiB
// higher — llama.cpp then offloads fewer layers — and a second OOM, on an
// automatic choice with the 4B installed, runs the 4B.
// Mutation (F2'): internal/daemon/notesfit.go notesSpawnPlan — drop the
// `if esc > 0 { target += notesFitOOMStepMiB }` step -> RED (the retry's
// target equals the first spawn's).
func TestAnOOMStartRaisesTheTargetThenFallsBack(t *testing.T) {
	d, dir := bothModels(t)
	t.Setenv("OXSAY_FAKE_LLM_OOM", "9B") // any spawn on the 9B fails to allocate
	fakeBudget(t, ampleLimitMiB, othersMiB)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 3 {
		t.Fatalf("spawns = %d, want the first, the raised-target retry and the 4B: %v", len(args), args)
	}
	first := fitTargetOf(t, args[0])
	if !strings.Contains(modelOf(args[1]), "9B") {
		t.Fatalf("the retried spawn's model = %q, want the 9B again", modelOf(args[1]))
	}
	if got := fitTargetOf(t, args[1]); got != first+notesFitOOMStepMiB {
		t.Fatalf("retry --fit-target = %d, want the first spawn's %d raised by %d", got, first, notesFitOOMStepMiB)
	}
	if !strings.Contains(modelOf(args[2]), "4B") {
		t.Fatalf("the last spawn's model = %q, want the compact 4B", modelOf(args[2]))
	}
	if n := d.Status().Notes; n.Fit != "fallback_4b" {
		t.Fatalf("notes = %+v, want fit fallback_4b", n)
	}
}

// An OOM on a saved choice retries once — the target raised — and then
// reports the failure honestly: no model swap, ever.
// Mutation: internal/daemon/notesfit.go notesEscalate — let the ceiling be 2
// for every resolution -> RED (a third spawn takes the 4B).
func TestAnOOMOnASavedChoiceRetriesOnceAndNeverSwaps(t *testing.T) {
	d, dir := bothModels(t)
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OXSAY_FAKE_LLM_OOM", "1") // every spawn OOMs
	fakeBudget(t, ampleLimitMiB, othersMiB)
	if err := complete(t, d); err == nil {
		t.Fatal("complete succeeded; the saved 9B that never loads must fail")
	}
	args := spawnArgvs(t, dir)
	if len(args) != 2 {
		t.Fatalf("spawns = %d, want the first and the one raised-target retry", len(args))
	}
	for i, a := range args {
		if m := modelOf(a); !strings.Contains(m, "9B") {
			t.Fatalf("spawn %d ran %q — a saved choice was swapped", i, m)
		}
	}
	if fitTargetOf(t, args[1]) <= fitTargetOf(t, args[0]) {
		t.Fatalf("the retry's target %d is not above the first's %d", fitTargetOf(t, args[1]), fitTargetOf(t, args[0]))
	}
}

// doubleOOM drives a meeting's notes through two OOMs on the 9B so the 4B
// serves them, then idles the 4B out.
func doubleOOM(t *testing.T, d *Daemon, dir string) {
	t.Helper()
	t.Setenv("OXSAY_FAKE_LLM_OOM", "9B")
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	if n := len(spawnArgvs(t, dir)); n != 3 {
		t.Fatalf("spawns = %d, want 3 (9B, 9B, 4B)", n)
	}
	t.Setenv("OXSAY_FAKE_LLM_OOM", "") // the spike is over
	// The idle stop: the 4B leaves, the next call spawns afresh.
	if err := d.LLMSup.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func injectClock(d *Daemon) *atomic.Int64 {
	var offset atomic.Int64
	base := time.Now()
	d.fit.now = func() time.Time { return base.Add(time.Duration(offset.Load())) }
	return &offset
}

// F3': one transient double OOM must not pin the 4B for the daemon's life:
// inside the TTL the floor holds, past it the automatic choice gets the 9B
// again.
// Mutation: internal/daemon/notesfit.go fitEscalation — drop the
// `clock().Sub(escAt) >= notesFloorTTL` condition -> RED (the 4B after 11
// minutes).
func TestTheOOMFloorLiftsAfterTheTTL(t *testing.T) {
	d, dir := bothModels(t)
	clock := injectClock(d)
	fakeBudget(t, ampleLimitMiB, othersMiB)
	doubleOOM(t, d, dir)

	clock.Store(int64(notesFloorTTL - time.Minute))
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if m := modelOf(args[len(args)-1]); !strings.Contains(m, "4B") {
		t.Fatalf("9 minutes after the OOMs the spawn ran %q, want the floor (4B) to hold", m)
	}
	if err := d.LLMSup.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}

	clock.Store(int64(notesFloorTTL + time.Minute))
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args = spawnArgvs(t, dir)
	if m := modelOf(args[len(args)-1]); !strings.Contains(m, "9B") {
		t.Fatalf("11 minutes after the OOMs the spawn ran %q, want the 9B again", m)
	}
	if n := d.Status().Notes; n.Fit != "full" {
		t.Fatalf("notes = %+v, want fit full once the floor lifted", n)
	}
}

// The next meeting's notes job starts with the floor lifted, whatever the
// clock says.
// Mutation: internal/daemon/meetings.go the NotesTurn wrapper — delete the
// d.liftNotesFloor() call -> RED (the 4B after the new job's turn).
func TestTheOOMFloorLiftsAtTheNextMeetingsNotesJob(t *testing.T) {
	d, dir := bothModels(t)
	injectClock(d)
	fakeBudget(t, ampleLimitMiB, othersMiB)
	doubleOOM(t, d, dir)
	if d.Meet.NotesTurn == nil {
		t.Fatal("the runner has no NotesTurn wired")
	}
	release, err := d.Meet.NotesTurn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	release()
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if m := modelOf(args[len(args)-1]); !strings.Contains(m, "9B") {
		t.Fatalf("the next meeting's job ran %q, want the 9B again", m)
	}
}

// With the budget unknown the llama.cpp default margin applies, /status says
// "unchecked" — and a proven OOM still raises the floor.
// Mutation: internal/daemon/notesfit.go notesSpawnPlan — return before
// fitEscalation when !known -> RED (the retry's target stays 1024).
func TestAnUnknownBudgetIsUncheckedButTheOOMFloorStillApplies(t *testing.T) {
	d, dir := bothModels(t)
	fakeBudgetFn(t, func() (uint64, uint64) { return 0, 0 })
	t.Setenv("OXSAY_FAKE_LLM_OOM", "9B")
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 3 {
		t.Fatalf("spawns = %d, want 3 (9B, raised 9B, 4B): %v", len(args), args)
	}
	if got := fitTargetOf(t, args[0]); got != notesFitDefaultTargetMiB {
		t.Fatalf("first --fit-target = %d, want llama.cpp's default %d", got, notesFitDefaultTargetMiB)
	}
	if got := fitTargetOf(t, args[1]); got != notesFitDefaultTargetMiB+notesFitOOMStepMiB {
		t.Fatalf("retry --fit-target = %d, want %d", got, notesFitDefaultTargetMiB+notesFitOOMStepMiB)
	}
	if !strings.Contains(modelOf(args[2]), "4B") {
		t.Fatalf("the last spawn ran %q, want the 4B", modelOf(args[2]))
	}
}

func TestAnUnknownBudgetReportsUnchecked(t *testing.T) {
	d, dir := bothModels(t)
	fakeBudgetFn(t, func() (uint64, uint64) { return 0, 0 })
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	if got := fitTargetOf(t, spawnArgvs(t, dir)[0]); got != notesFitDefaultTargetMiB {
		t.Fatalf("--fit-target = %d, want the default %d", got, notesFitDefaultTargetMiB)
	}
	if n := d.Status().Notes; n.Fit != "unchecked" || n.FitReason == "" {
		t.Fatalf("notes = %+v, want fit unchecked with its reason", n)
	}
}

// F1': the stale check compares the resolution with the one the resident
// child was spawned for — it never re-plans. The rest of the system's
// allocation grows while the engine is resident (the figure also counts the
// engine's own weights); five chunks later nothing may have respawned or
// relabelled.
// Mutation: internal/daemon/meetings.go notesStaleChild — compare against
// d.notesSpawnPlan().model instead of the stored spawn -> RED (the grown
// figure plans the 4B, the resident 9B is "stale", the engine respawns).
func TestAResidentEngineIsNotReplanned(t *testing.T) {
	d, dir := bothModels(t)
	var used atomic.Uint64
	used.Store(othersMiB)
	fakeBudgetFn(t, func() (uint64, uint64) { return ampleLimitMiB * mib, used.Load() * mib })
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	fit0, why0 := d.fitSnapshot()
	used.Store(ampleLimitMiB - 2<<10) // the 9B itself plus a loaded browser: little "free" left
	for i := range 5 {
		if err := complete(t, d); err != nil {
			t.Fatalf("complete %d: %v", i, err)
		}
	}
	if n := len(spawnArgvs(t, dir)); n != 1 {
		t.Fatalf("spawns = %d across 6 chunks, want 1 — the resident engine was recycled", n)
	}
	if fit, why := d.fitSnapshot(); fit != fit0 || why != why0 {
		t.Fatalf("status fit changed from (%q,%q) to (%q,%q) with no spawn", fit0, why0, fit, why)
	}
}

// A resolution that changed under a resident engine still recycles it.
func TestAChangedResolutionRecyclesTheResidentEngine(t *testing.T) {
	d, dir := notesFitDaemon(t, config.NotesModelFile)
	fakeBudget(t, ampleLimitMiB, othersMiB)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	// The 9B lands: the automatic choice now resolves to it.
	p := filepath.Join(d.Cfg.ModelsDir(), "Qwen3.5-9B-Q4_K_M.gguf")
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 2 || !strings.Contains(modelOf(args[1]), "9B") {
		t.Fatalf("spawns = %v, want a second spawn on the 9B", args)
	}
}

// MINOR-2: the /status label is rewritten by every plan, early returns
// included — a CPU-decode or missing-model plan after a fallback must not
// keep reporting fallback_4b.
// Mutation: internal/daemon/notesfit.go notesSpawnPlan — `return p` instead
// of `return d.finishPlan(res, p)` on the first early return -> RED.
func TestTheFitLabelFollowsEveryPlan(t *testing.T) {
	d, _ := bothModels(t)
	fakeBudget(t, tightLimitMiB, othersMiB)
	if p := d.notesSpawnPlan(); p.fit != "fallback_4b" {
		t.Fatalf("plan = %+v, want the fallback", p)
	}
	d.Cfg.GPUMemory = config.GPUMemoryDiscrete // CPU decode: no fitter, no label
	if p := d.notesSpawnPlan(); p.fitMiB != 0 || p.fit != "" {
		t.Fatalf("CPU decode plan = %+v, want no fit", p)
	}
	if fit, why := d.fitSnapshot(); fit != "" || why != "" {
		t.Fatalf("status = (%q,%q), want the stale fallback label cleared", fit, why)
	}
}

// MINOR-3: the scan reads the TAIL of what the child wrote since the mark,
// and a mark past the end of the file (the supervisor truncated the log)
// means everything in it is new.
// Mutation: internal/daemon/notesfit.go notesLogSince — read from `start`
// without the tail clamp (drop the `st.Size()-start > notesOOMScanTail`
// branch) -> the head-heavy case goes RED; drop the `start > st.Size()`
// reset -> the truncation case goes RED.
func TestTheOOMScanReadsTheTailAndSurvivesTruncation(t *testing.T) {
	d, _ := bothModels(t)
	logPath := filepath.Join(d.Cfg.EngineLogDir, "notes.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(s string) {
		t.Helper()
		if err := os.WriteFile(logPath, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	oom := "llama_kv_cache_init: failed to allocate KV self buffer\n"
	filler := strings.Repeat("load_tensors: tensor line "+strings.Repeat("x", 80)+"\n", 5000) // ~500 KiB

	write(filler + oom)
	if !d.notesStartOOMed(0) {
		t.Error("an OOM line after 500 KiB of tensor lines was missed (head read)")
	}
	write("old run: out of memory\n" + filler)
	mark := notesLogMark(d.Cfg.EngineLogDir)
	if d.notesStartOOMed(mark) {
		t.Error("an OOM line from before the mark was reported as this start's")
	}
	write(oom) // truncated below the mark, then a new child failed
	if !d.notesStartOOMed(mark) {
		t.Error("the OOM after a log truncation was missed (mark past the end)")
	}
	write(filler)
	if d.notesStartOOMed(0) {
		t.Error("a log with no OOM line reported one")
	}
}

// notesOOMSignatures is the contract the fake child and the detector share;
// a signature that stops matching real llama-server words fails this test
// before any fake does. The benign lines are the pinned llama.cpp's own
// fitter output (captured at -lv 4): none may look like an OOM, or a
// healthy start that the fitter trimmed would be retried.
func TestOOMSignaturesMatchRealLlamaWords(t *testing.T) {
	match := func(line string) bool {
		low := strings.ToLower(line)
		for _, sig := range notesOOMSignatures {
			if strings.Contains(low, sig) {
				return true
			}
		}
		return false
	}
	for _, line := range []string{
		"ggml_metal_device_alloc: failed to allocate workspace",
		"llama_kv_cache_init: failed to allocate KV self buffer",
		"error loading model: unable to allocate backend buffer",
		"ggml_backend_alloc_buffer: cannot allocate 1234.56 MB",
	} {
		if !match(line) {
			t.Errorf("no signature matches %q — a real OOM would go unretried", line)
		}
	}
	for _, line := range []string{
		"common_params_fit_impl: cannot meet free memory target of 35000 MiB, need to reduce device memory by 2336 MiB",
		"common_params_fit_impl: projected to use 5473 MiB of device memory vs. 38136 MiB of free device memory",
		"common_fit_params: failed to fit params to free device memory: n_gpu_layers already set by user to 99, abort",
		"common_params_fit_impl:   - MTL0 (Apple M5 Pro): 16 layers,   3068 MiB used,  35067 MiB free",
		"llama_kv_cache: size =  255.00 MiB ( 15360 cells,   8 layers,  4/1 seqs), K (q8_0):  127.50 MiB",
	} {
		if match(line) {
			t.Errorf("the healthy fitter line %q matches an OOM signature", line)
		}
	}
}

// The notes child must never run at debug verbosity: llama-server then logs
// request and response bodies and every prompt token, which would put the
// meeting transcript into notes.log in plain text.
// Mutation: internal/daemon/meetings.go notesArgs — add "-lv", "4" to the
// argv literal -> RED.
func TestTheNotesChildNeverRunsAtDebugVerbosity(t *testing.T) {
	d, _ := bothModels(t)
	forbidden := []string{"-lv", "--verbosity", "--log-verbosity", "-v", "--verbose", "--log-verbose"}
	argvs := map[string][]string{
		"default":  notesServerArgs(d.Cfg, 1234, "m.gguf"),
		"fit plan": notesPlanArgs(d.Cfg, 1234, notesPlan{model: "m.gguf", fitMiB: 4608}),
		"cpu plan": notesPlanArgs(d.Cfg, 1234, notesPlan{model: "m.gguf"}),
	}
	for name, args := range argvs {
		for _, f := range forbidden {
			if slices.Contains(args, f) {
				t.Errorf("%s argv carries %s: %q", name, f, strings.Join(args, " "))
			}
		}
	}
	for _, mem := range []string{config.GPUMemoryUnified, config.GPUMemoryDiscrete} {
		d.Cfg.GPUMemory = mem
		for _, e := range notesServerEnv(d.Cfg) {
			if strings.HasPrefix(e, "LLAMA_ARG_VERBOSITY") || strings.HasPrefix(e, "LLAMA_LOG_VERBOSITY") || strings.HasPrefix(e, "LLAMA_ARG_VERBOSE") {
				t.Errorf("%s env carries %s", mem, e)
			}
		}
	}
}
