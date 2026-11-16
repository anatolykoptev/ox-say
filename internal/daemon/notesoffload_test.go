package daemon

// What the notes child's own log says about its GPU offload (notesfit.go recordNotesOffload), the outcome /status
// reports next to the plan's fit label (#540). The fake ox-llm prints llama.cpp's load_tensors line verbatim.

import (
	"testing"
)

func TestParseNotesOffload(t *testing.T) {
	cases := []struct {
		name string
		log  string
		want notesOffload
		ok   bool
	}{
		{"the real line", "load_tensors: offloading output layer to GPU\nload_tensors: offloaded 33/33 layers to GPU\nload_tensors: Metal model buffer size = 5500.00 MiB\n", notesOffload{33, 33}, true},
		{"part on the CPU", "load_tensors: offloaded 20/33 layers to GPU\n", notesOffload{20, 33}, true},
		{"none on the GPU", "load_tensors: offloaded 0/33 layers to GPU\n", notesOffload{0, 33}, true},
		{"the last line wins", "load_tensors: offloaded 33/33 layers to GPU\n...\nload_tensors: offloaded 12/33 layers to GPU\n", notesOffload{12, 33}, true},
		{"no line", "llama_kv_cache: size = 255.00 MiB\n", notesOffload{}, false},
		{"empty", "", notesOffload{}, false},
		{"more than the total", "offloaded 40/33 layers to GPU\n", notesOffload{}, false},
		{"a total of zero", "offloaded 0/0 layers to GPU\n", notesOffload{}, false},
		{"a negative count", "offloaded -1/33 layers to GPU\n", notesOffload{}, false},
	}
	for _, c := range cases {
		got, ok := parseNotesOffload([]byte(c.log))
		if ok != c.ok || got != c.want {
			t.Errorf("%s: parseNotesOffload = %+v, %v; want %+v, %v", c.name, got, ok, c.want, c.ok)
		}
	}
}

// The count the child reports is in /status, beside the plan label that stays "full": a model the fitter put partly
// on the CPU is visible, not hidden behind the plan.
// Mutation: internal/daemon/meetings.go, the `c.d.recordNotesOffload(mark)` call after EnsureReady — delete it ->
// RED (Offload stays nil).
func TestTheOffloadOutcomeReachesStatus(t *testing.T) {
	d, _ := bothModels(t)
	t.Setenv("OXSAY_FAKE_LLM_OFFLOAD", "20/33")
	fakeBudget(t, ampleLimitMiB, othersMiB)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	n := d.Status().Notes
	if n.Offload == nil || *n.Offload != (notesOffload{GPULayers: 20, TotalLayers: 33}) {
		t.Fatalf("notes.offload = %+v, want 20 of 33 layers on the GPU", n.Offload)
	}
	if n.Fit != fitFull {
		t.Fatalf("notes.fit = %q: the plan label stays what was asked for", n.Fit)
	}
}

// A child that says nothing leaves the answer unknown — never "on the CPU" — and a new spawn does not inherit the
// previous child's count (its line is still in the log, before the new mark).
// Mutation: internal/daemon/notesfit.go finishPlan — delete `d.fit.offload = nil` -> RED (the second child
// reports the first one's 20/33). Mutation: internal/daemon/meetings.go — pass 0 instead of mark to
// recordNotesOffload -> RED (the old line is read again).
func TestASpawnThatSaysNothingLeavesTheOffloadUnknown(t *testing.T) {
	d, _ := bothModels(t)
	fakeBudget(t, ampleLimitMiB, othersMiB)
	t.Setenv("OXSAY_FAKE_LLM_OFFLOAD", "20/33")
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	if d.Status().Notes.Offload == nil {
		t.Fatal("the first child's count was not recorded")
	}
	if err := d.LLMSup.Stop(t.Context()); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OXSAY_FAKE_LLM_OFFLOAD", "")
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	if o := d.Status().Notes.Offload; o != nil {
		t.Fatalf("notes.offload = %+v after a spawn that reported nothing, want unknown (nil)", *o)
	}
}
