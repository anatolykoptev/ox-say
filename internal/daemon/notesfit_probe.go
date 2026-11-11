package daemon

// The GPU budget probe behind the notes fit check, split from the darwin
// file so the composition and the parsers run on the Linux CI too: only the
// raw sysctl read lives behind the build tag, everything else takes its
// inputs as seams.
//
// Both real sources were measured on a stock Mac (no sudo, no cgo):
//
//   - the limit is Metal's recommendedMaxWorkingSetSize, which the pinned
//     llama-server prints in `ox-llm --list-devices` ("MTL0: ... (38338 MiB,
//     38337 MiB free)": the first figure is the total). The call costs about
//     3 s of Metal init, so it runs in the background (at daemon start, and
//     again at a spawn while the total is still unknown, one at a time) and
//     until it answers the limit is unknown; once it has answered it never
//     runs again in this process. An explicit
//     iogpu.wired_limit_mb (> 0: the user's or the gate's own setting, which
//     Metal follows) wins; 0 there means "the system default", not unknown.
//   - what is already allocated, system-wide (the STT engines, the window
//     server, the browser in the call) is the IOAccelerator
//     PerformanceStatistics "Alloc system memory" read through ioreg, fresh
//     before each spawn.
//
// Any failure — a missing binary, a timeout, an output nobody recognises —
// reports unknown: /status says "unchecked" and llama.cpp fits with its
// default margin (the OOM retry still guards).

import (
	"context"
	"log/slog"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// ioregPath is exec'd by absolute path: the daemon runs with a
	// LaunchAgent's minimal PATH.
	ioregPath = "/usr/sbin/ioreg"

	ioregTimeout       = 2 * time.Second
	listDevicesTimeout = 30 * time.Second
)

var (
	// mtlDeviceRe matches the Metal device line of `--list-devices`.
	mtlDeviceRe = regexp.MustCompile(`(?m)^\s*MTL\d+:.*\((\d+) MiB, \d+ MiB free\)`)
	// allocRe matches one accelerator's allocated bytes.
	allocRe = regexp.MustCompile(`"Alloc system memory"=(\d+)`)
)

// parseListDevicesTotal returns the first Metal device's total memory in
// bytes from `ox-llm --list-devices` output; ok is false when no Metal
// device line (or only a zero total) is present.
func parseListDevicesTotal(out string) (uint64, bool) {
	m := mtlDeviceRe.FindStringSubmatch(out)
	if m == nil {
		return 0, false
	}
	mib, err := strconv.ParseUint(m[1], 10, 64)
	if err != nil || mib == 0 {
		return 0, false
	}
	return mib << 20, true
}

// parseIoregAlloc sums "Alloc system memory" (bytes) over every
// PerformanceStatistics line of `ioreg -r -d 1 -c IOAccelerator` output; ok
// is false when no such figure is present.
func parseIoregAlloc(out string) (uint64, bool) {
	var sum uint64
	found := false
	for line := range strings.SplitSeq(out, "\n") {
		if !strings.Contains(line, `"PerformanceStatistics"`) {
			continue
		}
		m := allocRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		n, err := strconv.ParseUint(m[1], 10, 64)
		if err != nil {
			continue
		}
		sum += n
		found = true
	}
	return sum, found
}

// cmdRunner runs a command and returns its stdout.
type cmdRunner func(ctx context.Context, name string, args ...string) (string, error)

func execRun(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).Output()
	return string(out), err
}

// gpuProbe composes the limit and the used figure from its seams.
type gpuProbe struct {
	sysctlMB func() uint64 // iogpu.wired_limit_mb; 0 = unset or unreadable
	run      cmdRunner

	retrying atomic.Bool    // a --list-devices call is in flight
	wg       sync.WaitGroup // the background calls, for tests to wait on
	metal    atomic.Uint64  // bytes; 0 until known
	warnOnce sync.Once
}

func newGPUProbe(sysctlMB func() uint64, run cmdRunner) *gpuProbe {
	return &gpuProbe{sysctlMB: sysctlMB, run: run}
}

// warm starts a background --list-devices call unless the total is known
// already or a call is in flight: at most one at a time, never blocking its
// caller, and none after a success.
func (p *gpuProbe) warm(bin string) {
	if p.metal.Load() != 0 || !p.retrying.CompareAndSwap(false, true) {
		return
	}
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		defer p.retrying.Store(false)
		if p.metal.Load() != 0 {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), listDevicesTimeout)
		defer cancel()
		out, err := p.run(ctx, bin, "--list-devices")
		total, ok := parseListDevicesTotal(out)
		if err != nil || !ok {
			slog.Warn("notes fit: Metal memory total unavailable; the GPU budget is unchecked until a later start reads it", "err", err, "parsed", ok)
			return
		}
		p.metal.Store(total)
	}()
}

// limit is the Metal wired limit in bytes, 0 while unknown. It never starts
// or waits for the Metal call.
func (p *gpuProbe) limit() uint64 {
	if mb := p.sysctlMB(); mb > 0 {
		return mb << 20
	}
	return p.metal.Load()
}

// used is the system-wide allocated GPU memory in bytes, read now.
func (p *gpuProbe) used() (uint64, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), ioregTimeout)
	defer cancel()
	out, err := p.run(ctx, ioregPath, "-r", "-d", "1", "-c", "IOAccelerator")
	n, ok := parseIoregAlloc(out)
	if err != nil || !ok {
		p.warnOnce.Do(func() {
			slog.Warn("notes fit: allocated GPU memory unreadable; the GPU fit check is skipped", "err", err, "parsed", ok)
		})
		return 0, false
	}
	return n, true
}

// wired is the (limit, used) pair notesGPUWired reports; (0, 0) is unknown.
// While the limit is unknown it starts (without waiting for) one background
// retry of the Metal read, so a start that missed it at daemon start gets it
// for the next spawn.
func (p *gpuProbe) wired(bin string) (limit, used uint64) {
	limit = p.limit()
	if limit == 0 {
		p.warm(bin)
		return 0, 0
	}
	used, ok := p.used()
	if !ok {
		return 0, 0
	}
	return limit, used
}
