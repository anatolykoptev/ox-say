package daemon

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
)

func init() {
	// The fake ox-llm is the test binary: never exec it for --list-devices —
	// neither at daemon start nor from a spawn-time retry (the real probe
	// would do both). A test that needs a budget installs its own.
	notesGPUWarmup = func(string) {}
	notesGPUWired = func(string) (uint64, uint64) { return 0, 0 }
}

// Fixtures: the two outputs measured on a stock M5 Pro, byte for byte.
const (
	listDevicesFixture = "Available devices:\n" +
		"  MTL0: Apple M5 Pro (38338 MiB, 38337 MiB free)\n" +
		"  BLAS: Accelerate (0 MiB, 0 MiB free)\n"
	ioregFixture = `      "PerformanceStatistics" = {"In use system memory (driver)"=0,"Alloc system memory"=4014014464,"Tiler Utilization %"=0,"recoveryCount"=0,"lastRecoveryTime"=0,"Renderer Utilization %"=0,"TiledSceneBytes"=589824,"Device Utilization %"=0,"SplitSceneCount"=0,"Allocated PB Size"=106954752,"In use system memory"=1125154816}` + "\n"
)

func TestParseListDevicesTotal(t *testing.T) {
	for _, tc := range []struct {
		name, out string
		want      uint64
		ok        bool
	}{
		{"fixture", listDevicesFixture, 38338 << 20, true},
		{"empty", "", 0, false},
		{"malformed", "MTL0: broken (lots MiB)\n", 0, false},
		{"cpu only", "Available devices:\n  BLAS: Accelerate (0 MiB, 0 MiB free)\n", 0, false},
		{"zero total", "  MTL0: X (0 MiB, 0 MiB free)\n", 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseListDevicesTotal(tc.out)
			if got != tc.want || ok != tc.ok {
				t.Errorf("parseListDevicesTotal = (%d,%v), want (%d,%v)", got, ok, tc.want, tc.ok)
			}
		})
	}
}

func TestParseIoregAlloc(t *testing.T) {
	two := ioregFixture + strings.Replace(ioregFixture, "4014014464", "1000", 1)
	for _, tc := range []struct {
		name, out string
		want      uint64
		ok        bool
	}{
		{"fixture takes Alloc system memory", ioregFixture, 4014014464, true},
		{"several accelerators are summed", two, 4014014464 + 1000, true},
		{"empty", "", 0, false},
		{"malformed", `"PerformanceStatistics" = {"Alloc system memory"=}` + "\n", 0, false},
		{"other lines ignored", `"Alloc system memory"=5` + "\n", 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseIoregAlloc(tc.out)
			if got != tc.want || ok != tc.ok {
				t.Errorf("parseIoregAlloc = (%d,%v), want (%d,%v)", got, ok, tc.want, tc.ok)
			}
		})
	}
}

// fakeRunner answers --list-devices and ioreg and counts the calls.
type fakeRunner struct {
	listCalls, ioregCalls atomic.Int32
	mu                    sync.Mutex
	listErr, ioregErr     error
	ioregOut              string
}

func (f *fakeRunner) setListErr(err error) {
	f.mu.Lock()
	f.listErr = err
	f.mu.Unlock()
}

func (f *fakeRunner) run(_ context.Context, name string, args ...string) (string, error) {
	if name == ioregPath {
		f.ioregCalls.Add(1)
		return f.ioregOut, f.ioregErr
	}
	f.listCalls.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	return listDevicesFixture, f.listErr
}

func newFakeProbe(sysctlMB uint64, f *fakeRunner) *gpuProbe {
	return newGPUProbe(func() uint64 { return sysctlMB }, f.run)
}

// wiredWarm warms the probe and waits for the background read.
func wiredWarm(p *gpuProbe) (uint64, uint64) {
	p.warm("ox-llm")
	p.wg.Wait()
	return p.wired("ox-llm")
}

// Mutation (F6): notesfit_probe.go gpuProbe.limit, return 0 instead of the
// Metal total (p.metal.Load()) when the sysctl is 0 -> this goes RED.
func TestProbeLimitFallsBackToMetalWhenSysctlZero(t *testing.T) {
	f := &fakeRunner{ioregOut: ioregFixture}
	limit, used := wiredWarm(newFakeProbe(0, f))
	if limit != 38338<<20 || used != 4014014464 {
		t.Errorf("wired = (%d,%d), want (%d,%d)", limit, used, uint64(38338<<20), uint64(4014014464))
	}
}

func TestProbeSysctlWinsOverMetal(t *testing.T) {
	f := &fakeRunner{ioregOut: ioregFixture}
	p := newFakeProbe(10922, f)
	limit, _ := p.wired("ox-llm")
	if limit != 10922<<20 {
		t.Errorf("limit = %d, want the sysctl's 10922 MiB", limit)
	}
	if f.listCalls.Load() != 0 {
		t.Errorf("--list-devices ran %d times with an explicit sysctl limit, want 0", f.listCalls.Load())
	}
}

// Mutation (F8): notesfit_probe.go gpuProbe.warm, drop the
// `p.metal.Load() != 0 ||` guard so a known total is read again at every
// spawn -> this goes RED.
func TestProbeListDevicesRunsOncePerProcess(t *testing.T) {
	f := &fakeRunner{ioregOut: ioregFixture}
	p := newFakeProbe(0, f)
	wiredWarm(p)
	p.wired("ox-llm")
	p.wired("ox-llm")
	p.wg.Wait()
	if n := f.listCalls.Load(); n != 1 {
		t.Errorf("--list-devices ran %d times across three spawns, want 1", n)
	}
	if n := f.ioregCalls.Load(); n != 3 {
		t.Errorf("ioreg ran %d times across three spawns, want 3 (fresh each spawn)", n)
	}
}

// While the total is unknown a spawn-time read reports unknown at once and
// starts the one background retry; it never waits for it.
func TestProbeUnknownUntilWarmed(t *testing.T) {
	f := &fakeRunner{ioregOut: ioregFixture}
	p := newFakeProbe(0, f)
	if limit, used := p.wired("ox-llm"); limit != 0 || used != 0 {
		t.Errorf("wired before warm = (%d,%d), want unknown (0,0)", limit, used)
	}
	p.wg.Wait()
	if limit, _ := p.wired("ox-llm"); limit != 38338<<20 {
		t.Errorf("limit after the retry = %d, want 38338 MiB", limit)
	}
}

// MINOR-1: a --list-devices call that failed at daemon start (GPU busy at
// login) is retried by a later spawn instead of disabling the check for the
// process lifetime.
// Mutation (F5'): notesfit_probe.go gpuProbe.wired, drop the `p.warm(bin)`
// call on an unknown limit -> this goes RED.
func TestProbeRetriesTheMetalReadWhileUnknown(t *testing.T) {
	f := &fakeRunner{ioregOut: ioregFixture, listErr: errors.New("gpu busy")}
	p := newFakeProbe(0, f)
	if limit, _ := wiredWarm(p); limit != 0 {
		t.Fatalf("limit = %d after a failed read, want unknown", limit)
	}
	f.setListErr(nil)
	p.wired("ox-llm") // a spawn: unknown still, starts the retry
	p.wg.Wait()
	limit, used := p.wired("ox-llm")
	if limit != 38338<<20 || used != 4014014464 {
		t.Errorf("wired after the retry = (%d,%d), want (%d,%d)", limit, used, uint64(38338<<20), uint64(4014014464))
	}
	if n := f.listCalls.Load(); n != 2 {
		t.Errorf("--list-devices ran %d times, want the failed one and one retry", n)
	}
}

// At most one read is in flight: a burst of spawns while it runs starts no
// second one.
func TestProbeRetryIsSingleFlight(t *testing.T) {
	release := make(chan struct{})
	var calls atomic.Int32
	p := newGPUProbe(func() uint64 { return 0 }, func(ctx context.Context, name string, args ...string) (string, error) {
		if name == ioregPath {
			return ioregFixture, nil
		}
		calls.Add(1)
		<-release
		return "", errors.New("still busy")
	})
	for range 5 {
		p.wired("ox-llm")
	}
	close(release)
	p.wg.Wait()
	if n := calls.Load(); n != 1 {
		t.Errorf("%d --list-devices calls in flight at once, want 1", n)
	}
}

// F4': newLLMSupervisor warms the Metal read with the notes binary — through
// the same notesGPUWarmup var production calls. Without it a stock Mac
// (sysctl 0) would start every spawn unchecked.
// Mutation (F4'): meetings.go newLLMSupervisor, replace the notesGPUWarmup
// call with `_ = notesGPUWarmup` -> this goes RED.
func TestNewLLMSupervisorWarmsTheMetalRead(t *testing.T) {
	d, _ := notesFitDaemon(t)
	var got atomic.Value
	old := notesGPUWarmup
	notesGPUWarmup = func(bin string) { got.Store(bin) }
	t.Cleanup(func() { notesGPUWarmup = old })
	if _, err := newLLMSupervisor(d); err != nil {
		t.Fatal(err)
	}
	if bin, _ := got.Load().(string); bin != notesBinPath(d.Cfg) {
		t.Errorf("warmup bin = %q, want %q", bin, notesBinPath(d.Cfg))
	}
}

func TestProbeDiscreteCardsAreNotWarmed(t *testing.T) {
	d, _ := notesFitDaemon(t)
	d.Cfg.GPUMemory = config.GPUMemoryDiscrete
	var calls atomic.Int32
	old := notesGPUWarmup
	notesGPUWarmup = func(string) { calls.Add(1) }
	t.Cleanup(func() { notesGPUWarmup = old })
	if _, err := newLLMSupervisor(d); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 0 {
		t.Errorf("a discrete-memory daemon warmed the Metal read")
	}
}

func TestProbeFailuresAreUnknown(t *testing.T) {
	boom := errors.New("boom")
	for _, tc := range []struct {
		name string
		f    *fakeRunner
	}{
		{"ioreg error", &fakeRunner{ioregOut: ioregFixture, ioregErr: boom}},
		{"ioreg garbage", &fakeRunner{ioregOut: "nothing here"}},
		{"list-devices error", &fakeRunner{ioregOut: ioregFixture, listErr: boom}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if limit, used := wiredWarm(newFakeProbe(0, tc.f)); limit != 0 || used != 0 {
				t.Errorf("wired = (%d,%d), want unknown (0,0)", limit, used)
			}
		})
	}
}

// Mutation (F7): notesfit_probe.go allocRe, match "In use system memory"
// instead of "Alloc system memory" -> TestParseIoregAlloc/fixture goes RED.
