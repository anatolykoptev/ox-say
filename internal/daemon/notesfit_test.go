package daemon

// The notes engine's start-time GPU fit check (notesfit.go): the argv the
// spawn gets — model file and -ngl — decided from the budget actually free
// when the child starts, the automatic-only rung onto the installed compact
// model, and the OOM retry that walks the same ladder when the estimate was
// wrong. The GPU probe is replaced (notesGPUWired) and the fake ox-llm
// stamps every spawn's argv and can OOM a start on demand.

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

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

// fakeWired makes the GPU probe answer this much free wired budget.
func fakeWired(t *testing.T, free int64) {
	t.Helper()
	old := notesGPUWired
	notesGPUWired = func(string) (limit, used uint64) { return uint64(free) + (500 << 20), 500 << 20 }
	t.Cleanup(func() { notesGPUWired = old })
}

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

func nglOf(t *testing.T, args []string) int {
	t.Helper()
	n, err := strconv.Atoi(notesFlagValue(args, "-ngl"))
	if err != nil {
		t.Fatalf("no numeric -ngl in %q", strings.Join(args, " "))
	}
	return n
}

// notesNeedOf is the resolution's own estimate, for budgets the test aims
// between "fits" and "does not".
func notesNeedOf(t *testing.T, d *Daemon) (need, perLayer, layers int64) {
	t.Helper()
	return notesModelNeed(d.notesResolve())
}

// F1: the automatic 9B, a budget too small for its full offload but holding
// a real part of it → the spawn runs with a reduced -ngl and /status says
// partial_offload.
// Mutation: internal/daemon/meetings.go notesEngineConfig — Args returns the
// default argv without calling the plan -> RED (-ngl 99, no fit).
func TestNotesPartialOffloadWhenFullDoesNotFit(t *testing.T) {
	d, dir := notesFitDaemon(t, "Qwen3.5-9B-Q4_K_M.gguf", config.NotesModelFile)
	_, perLayer, layers := notesNeedOf(t, d)
	// Full offload needs layers*perLayer + compute + headroom; give the
	// budget room for a real part of the model and no more.
	fakeWired(t, notesFitHeadroom+notesComputeBytes+int64(notesMinPartialLayers+3)*perLayer)
	out, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	if err != nil || out == "" {
		t.Fatalf("complete = %q, %v", out, err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 {
		t.Fatalf("spawns = %d, want 1", len(args))
	}
	ngl := nglOf(t, args[0])
	if m := notesFlagValue(args[0], "-m"); !strings.Contains(m, "9B") {
		t.Fatalf("the spawn's model = %q, want the 9B", m)
	}
	if ngl < 1 || ngl >= int(layers) {
		t.Fatalf("-ngl = %d, want a partial offload under %d layers", ngl, layers)
	}
	if n := d.Status().Notes; n.Fit != "partial_offload" || n.FitReason == "" {
		t.Fatalf("notes = %+v, want fit partial_offload with its reason", n)
	}
}

// F2: the budget cannot hold even a sliver of the 9B, the compact model is
// installed and the choice is automatic → the notes run on the 4B and say so.
// Mutation: internal/daemon/notesfit.go notesSpawnPlan — delete the compact
// branch -> RED (the spawn keeps the 9B at -ngl 1).
func TestNotesFallbackToTheCompactModel(t *testing.T) {
	d, dir := notesFitDaemon(t, "Qwen3.5-9B-Q4_K_M.gguf", config.NotesModelFile)
	_, perLayer, _ := notesNeedOf(t, d)
	// Under notesMinPartialLayers of the 9B's movable part — but the compact
	// model's own partial offload still fits inside it.
	free := notesFitHeadroom + notesComputeBytes + int64(notesMinPartialLayers-1)*perLayer
	fakeWired(t, free)
	out, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	if err != nil || out == "" {
		t.Fatalf("complete = %q, %v", out, err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 {
		t.Fatalf("spawns = %d, want 1", len(args))
	}
	if m := notesFlagValue(args[0], "-m"); !strings.Contains(m, "4B") {
		t.Fatalf("the spawn's model = %q, want the compact 4B", m)
	}
	if n := d.Status().Notes; n.Fit != "fallback_4b" || n.FitReason == "" {
		t.Fatalf("notes = %+v, want fit fallback_4b with its reason", n)
	}
}

// F3: the same budget, but the 9B is the user's SAVED choice — it is never
// swapped for another model: the spawn keeps the 9B at the thinnest offload
// and /status says partial_offload.
// Mutation: internal/daemon/notesfit.go notesSpawnPlan — let the compact
// branch take non-automatic sources -> RED (the spawn runs the 4B).
func TestASavedChoiceIsNeverSwapped(t *testing.T) {
	d, dir := notesFitDaemon(t, "Qwen3.5-9B-Q4_K_M.gguf", config.NotesModelFile)
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	_, _, layers := notesNeedOf(t, d)
	// Between one layer of the compact model and one of the 9B: the compact
	// model fits while the resolved one does not — the rung where only a
	// model swap would help, and a saved choice must not take it.
	e := notesCompactEntry()
	_, perCompact, _ := notesModelNeed(config.NotesResolution{Entry: e, Installed: true})
	fakeWired(t, notesFitHeadroom+notesComputeBytes+perCompact)
	out, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	if err != nil || out == "" {
		t.Fatalf("complete = %q, %v", out, err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 {
		t.Fatalf("spawns = %d, want 1", len(args))
	}
	if m := notesFlagValue(args[0], "-m"); !strings.Contains(m, "9B") {
		t.Fatalf("a saved choice was swapped: the spawn's model = %q", m)
	}
	if ngl := nglOf(t, args[0]); ngl < 1 || ngl >= int(layers) {
		t.Fatalf("-ngl = %d, want some offload of the chosen model", ngl)
	}
	if n := d.Status().Notes; n.Fit == "fallback_4b" {
		t.Fatalf("notes = %+v — an explicit choice must never report fallback_4b", n)
	}
}

// F4: the estimate said the 9B fits, the spawn OOM'd anyway (the child's own
// stderr) → one retry partially offloaded, then — automatic with the 4B
// installed — the compact model; the notes complete on it.
// Mutation: internal/daemon/meetings.go llmChat.Complete — remove the retry
// loop -> RED (the first OOM is the call's answer).
func TestAnOOMStartRetriesDegradedThenCompact(t *testing.T) {
	d, dir := notesFitDaemon(t, "Qwen3.5-9B-Q4_K_M.gguf", config.NotesModelFile)
	t.Setenv("OXSAY_FAKE_LLM_OOM", "9B") // any spawn on the 9B fails to allocate
	fakeWired(t, 64<<30)                 // the estimate says everything fits
	out, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	if err != nil || out == "" {
		t.Fatalf("complete = %q, %v", out, err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 3 {
		t.Fatalf("spawns = %d, want the full, the partial and the 4B: %v", len(args), args)
	}
	if ngl := nglOf(t, args[0]); ngl != 99 {
		t.Fatalf("first spawn's -ngl = %d, want the full offload it attempted", ngl)
	}
	if m := notesFlagValue(args[1], "-m"); !strings.Contains(m, "9B") {
		t.Fatalf("the retried spawn's model = %q, want the 9B partially offloaded", m)
	}
	if ngl := nglOf(t, args[1]); ngl >= 99 || ngl < 1 {
		t.Fatalf("the retried spawn's -ngl = %d, want a partial offload", ngl)
	}
	if m := notesFlagValue(args[2], "-m"); !strings.Contains(m, "4B") {
		t.Fatalf("the last spawn's model = %q, want the compact 4B", m)
	}
	if n := d.Status().Notes; n.Fit != "fallback_4b" {
		t.Fatalf("notes = %+v, want fit fallback_4b", n)
	}
}

// An OOM on a saved choice retries once — partially offloaded — and then
// reports the failure honestly: no model swap, ever.
// Mutation: internal/daemon/notesfit.go notesEscalate — raise the saved
// choice's ceiling past 1 -> RED (a third spawn takes the 4B).
func TestAnOOMOnASavedChoiceRetriesOnceAndNeverSwaps(t *testing.T) {
	d, dir := notesFitDaemon(t, "Qwen3.5-9B-Q4_K_M.gguf", config.NotesModelFile)
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OXSAY_FAKE_LLM_OOM", "1") // every spawn OOMs
	fakeWired(t, 64<<30)
	out, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	if err == nil {
		t.Fatalf("complete = %q, nil; the saved 9B that never loads must fail", out)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 2 {
		t.Fatalf("spawns = %d, want the full and the one partial retry", len(args))
	}
	for i, a := range args {
		if m := notesFlagValue(a, "-m"); !strings.Contains(m, "9B") {
			t.Fatalf("spawn %d ran %q — a saved choice was swapped", i, m)
		}
	}
}

// notesOOMSignatures is the contract the fake child and the detector share;
// a signature that stops matching real llama-server words fails this test
// before any fake does.
func TestOOMSignaturesMatchRealLlamaWords(t *testing.T) {
	for _, line := range []string{
		"ggml_metal_device_alloc: failed to allocate workspace",
		"llama_kv_cache_init: failed to allocate KV self buffer",
		"error loading model: unable to allocate backend buffer",
		"ggml_backend_alloc_buffer: cannot allocate 1234.56 MB",
	} {
		low := strings.ToLower(line)
		found := false
		for _, sig := range notesOOMSignatures {
			if strings.Contains(low, sig) {
				found = true
			}
		}
		if !found {
			t.Errorf("no signature matches %q — a real OOM would go unretried", line)
		}
	}
}
