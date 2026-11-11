package daemon

// makeNotesRoom (notesfit.go): in shared mode a meeting's notes turn stops the idle voices when they leave the
// model less room than its weights, and /status stops calling a partly-CPU plan "full".

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// stopLog collects the engine names the arbiter's stop path was asked to stop.
type stopLog struct {
	mu sync.Mutex
	s  string
}

func (l *stopLog) Add(x string) { l.mu.Lock(); l.s += x; l.mu.Unlock() }
func (l *stopLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.s
}

var stopAttempts = &stopLog{}

// notesRoomDaemon is notesFitDaemon (the 9B installed, unified memory, shared mode) with both voices configured
// against their fake children, both resident, and a probe that reports voiceMiB of GPU memory used while any
// voice is up and restMiB otherwise.
func notesRoomDaemon(t *testing.T, limitMiB, voiceMiB, restMiB uint64) (*Daemon, string) {
	t.Helper()
	stopAttempts.mu.Lock()
	stopAttempts.s = ""
	stopAttempts.mu.Unlock()
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_CHILD", "1")
	t.Setenv("OXSAY_FAKE_VOX", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
	voxModel := filepath.Join(dir, config.VoxCPM2ModelFile)
	if err := os.WriteFile(voxModel, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	d, _ := meetingFixture(t, func(c *config.Config) {
		c.GPUMemory = config.GPUMemoryUnified
		c.NotesBin = os.Args[0]
		c.VoxCPM2Bin = os.Args[0]
		c.VoxCPM2Model = voxModel
		c.VoxCPM2Port = testutil.FreePort(t)
		p := filepath.Join(c.ModelsDir(), "Qwen3.5-9B-Q4_K_M.gguf")
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	})
	if d.VoxSup == nil || d.Sup == nil {
		t.Fatal("the fixture needs both voices")
	}
	if d.mem.managed(d.LLMSup) {
		t.Fatal("the fixture must be in shared mode")
	}
	// A shared-mode arbiter whose stop path records every attempt (the real Stop does the work).
	d.mem = &residency{change: make(chan struct{}), log: d.log, engines: []*engine.Supervisor{d.Sup, d.VoxSup, d.LLMSup},
		cond: func() bool { return false },
		stop: func(ctx context.Context, e *engine.Supervisor) error {
			stopAttempts.Add(e.Name() + ";")
			return e.Stop(ctx)
		}}
	for _, s := range []*engine.Supervisor{d.Sup, d.VoxSup} {
		if _, err := s.EnsureReady(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	// The fake dispatcher gives OXSAY_FAKE_LLM precedence in every child, so it is set only once the voices run.
	t.Setenv("OXSAY_FAKE_LLM", "1")
	fakeBudgetFn(t, func() (uint64, uint64) {
		if d.Sup.State() == engine.StateReady || d.VoxSup.State() == engine.StateReady {
			return limitMiB * mib, voiceMiB * mib
		}
		return limitMiB * mib, restMiB * mib
	})
	return d, dir
}

// F3: the room is under the 9B's weights + 1 GiB with the voices up; both are idle, so both are stopped before the
// notes engine is spawned, and the spawn is planned from the probe read after they exited.
// Mutation: internal/daemon/meetings.go llmChat.Complete, delete the `c.d.makeNotesRoom(ctx)` line -> RED (the
// voices stay up, the spawn is partial).
func TestNotesTurnStopsIdleVoicesWhenTheRoomIsShort(t *testing.T) {
	d, dir := notesRoomDaemon(t, 12<<10, 7<<10, 1<<10)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	if d.Sup.State() != engine.StateStopped || d.VoxSup.State() != engine.StateStopped {
		t.Fatalf("fast voice %s, studio voice %s: both idle voices must be stopped before the notes spawn", d.Sup.State(), d.VoxSup.State())
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 {
		t.Fatalf("notes spawns = %d, want 1", len(args))
	}
	if got, want := fitTargetOf(t, args[0]), (1<<10)+notesFitHeadroomMiB; got != want {
		t.Fatalf("--fit-target = %d, want %d: the spawn must be planned from the probe taken after the voices exited", got, want)
	}
	if n := d.Status().Notes; n.Fit != fitFull {
		t.Fatalf("notes.fit = %q, want full: the model fits once the voices are gone", n.Fit)
	}
}

// F4: a voice that is rendering is never stopped; the idle one is, and the spawn goes ahead with what room is left.
// Mutation: internal/daemon/notesfit.go makeNotesRoom, drop the `!v.Idle()` condition -> RED (the studio voice is
// stopped under its render).
func TestNotesTurnNeverStopsARenderingVoice(t *testing.T) {
	d, dir := notesRoomDaemon(t, 12<<10, 7<<10, 1<<10)
	g := d.VoxSup.Acquire() // a render in flight
	defer g.Release()
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stopAttempts.String(), d.VoxSup.Name()) {
		t.Fatalf("the arbiter's stop path was asked to stop the rendering studio voice (%q)", stopAttempts.String())
	}
	if d.VoxSup.State() != engine.StateReady {
		t.Fatalf("studio voice %s: it was rendering and must stay up", d.VoxSup.State())
	}
	if d.Sup.State() != engine.StateStopped {
		t.Fatalf("fast voice %s: it was idle and must be stopped", d.Sup.State())
	}
	if len(spawnArgvs(t, dir)) != 1 {
		t.Fatal("the notes engine must still be spawned")
	}
	if n := d.Status().Notes; n.Fit != fitPartial {
		t.Fatalf("notes.fit = %q, want partial: the studio voice still holds the room", n.Fit)
	}
}

// Enough room: the voices are left alone.
func TestNotesTurnLeavesVoicesWhenTheRoomIsEnough(t *testing.T) {
	d, _ := notesRoomDaemon(t, 24<<10, 3<<10, 1<<10)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	if d.Sup.State() != engine.StateReady || d.VoxSup.State() != engine.StateReady {
		t.Fatalf("fast voice %s, studio voice %s: with room to spare nothing is stopped", d.Sup.State(), d.VoxSup.State())
	}
}

// F5: the weights exceed the room, so /status says partial and why — never full.
// Mutation: internal/daemon/notesfit.go notesSpawnPlan, make the partial branch `if false && known && ...` -> RED.
func TestFitSaysPartialWhenTheWeightsExceedTheRoom(t *testing.T) {
	d, _ := bothModels(t)
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil { // never swapped
		t.Fatal(err)
	}
	fakeBudget(t, tightLimitMiB, othersMiB)
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	n := d.Status().Notes
	if n.Fit != fitPartial || !strings.Contains(n.FitReason, "CPU") {
		t.Fatalf("notes = %+v, want fit partial with a reason that names the CPU", n)
	}
}
