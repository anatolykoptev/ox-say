package config

import (
	"maps"
	"strings"
	"testing"
)

func oneEngineAt(t *testing.T, env map[string]string, gb uint64) *Config {
	t.Helper()
	orig := hostMemoryBytes
	t.Cleanup(func() { hostMemoryBytes = orig })
	hostMemoryBytes = func() uint64 { return gb * bytesPerGB }
	return loadEnv(t, env)
}

// The large GPU engines take turns only on Apple Silicon below OneLargeEngineBelowGB; an unknown size never turns it on.
// Mutation: config.go OneLargeEngine, flip `mem < OneLargeEngineBelowGB*bytesPerGB` to `>` -> the 16 GB case is false and
// the 32 GB case true -> RED; drop the `!c.UnifiedMemory()` guard -> the Intel case is true -> RED.
func TestOneLargeEngineThreshold(t *testing.T) {
	env, _, _ := voxEnv(t)
	cases := []struct {
		name string
		gb   uint64
		want bool
	}{
		{"16 GB", 16, true},
		{"23 GB", 23, true},
		{"24 GB is the floor", 24, false},
		{"48 GB", 48, false},
		{"unknown", 0, false},
	}
	for _, tc := range cases {
		if got := oneEngineAt(t, env, tc.gb).OneLargeEngine(); got != tc.want {
			t.Errorf("%s: OneLargeEngine = %v, want %v", tc.name, got, tc.want)
		}
	}
	intel := maps.Clone(env)
	intel["OX_SAY_GPU_MEMORY"] = GPUMemoryDiscrete
	if oneEngineAt(t, intel, 16).OneLargeEngine() {
		t.Error("a discrete-GPU Mac has its own lease; OneLargeEngine must be false")
	}
}

// OX_SAY_ASSUME_MEMORY_GB drives the eviction decision ALONE: a 48 GB Mac that assumes 16 GB evicts, yet the
// VoxCPM2 gate still reads the real 48 GB and offers the studio voice; a 16 GB Mac that assumes 48 GB does not evict
// and keeps the gate shut.
// Mutation: config.go load, set `c.HostMemoryBytes = c.AssumedMemoryBytes` when it is non-zero -> the 48 GB Mac that
// assumes 16 GB reports the studio voice unavailable -> RED.
func TestAssumeMemoryKnobDrivesOnlyTheEvictionPolicy(t *testing.T) {
	env, _, _ := voxEnv(t)
	env = maps.Clone(env)
	env["OX_SAY_ASSUME_MEMORY_GB"] = "16"
	big := oneEngineAt(t, env, 48)
	if !big.OneLargeEngine() {
		t.Error("assumed 16 GB on a 48 GB Mac: OneLargeEngine = false, want true")
	}
	if got := big.VoxCPM2Unavailable(); got != "" {
		t.Errorf("the assume knob must not touch the gate: 48 GB Mac reports %q", got)
	}
	if big.HostMemoryBytes != 48*bytesPerGB {
		t.Errorf("HostMemoryBytes = %d, want the real 48 GB", big.HostMemoryBytes)
	}

	env["OX_SAY_ASSUME_MEMORY_GB"] = "48"
	small := oneEngineAt(t, env, 16)
	if small.OneLargeEngine() {
		t.Error("assumed 48 GB: OneLargeEngine = true, want false")
	}
	if got := small.VoxCPM2Unavailable(); !strings.Contains(got, "24 GB") {
		t.Errorf("the assume knob must not open the gate on a real 16 GB Mac, got %q", got)
	}
}

func TestAssumeMemoryKnobRejectsGarbage(t *testing.T) {
	env, _, _ := voxEnv(t)
	for _, v := range []string{"abc", "0", "-4", "1.5"} {
		e := maps.Clone(env)
		e["OX_SAY_ASSUME_MEMORY_GB"] = v
		if _, err := load(func(k string) string { return e[k] }, nil); err == nil {
			t.Errorf("OX_SAY_ASSUME_MEMORY_GB=%q accepted, want an error", v)
		}
	}
}
