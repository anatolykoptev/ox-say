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
//     3 s of Metal init, so it runs once per daemon process, in the
//     background, and until it answers the limit is unknown. An explicit
//     iogpu.wired_limit_mb (> 0: the user's or the gate's own setting, which
//     Metal follows) wins; 0 there means "the system default", not unknown.
//   - what is already allocated, system-wide (the STT engines, the window
//     server, the browser in the call) is the IOAccelerator
//     PerformanceStatistics "Alloc system memory" read through ioreg, fresh
//     before each spawn.
//
// Any failure — a missing binary, a timeout, an output nobody recognises —
// reports unknown, which skips the fit check (the OOM retry still guards).

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

	startOnce sync.Once
	done      chan struct{} // closed when the --list-devices call finished
	metal     atomic.Uint64 // bytes; 0 until known or when it failed
	warnOnce  sync.Once
}

func newGPUProbe(sysctlMB func() uint64, run cmdRunner) *gpuProbe {
	return &gpuProbe{sysctlMB: sysctlMB, run: run, done: make(chan struct{})}
}

// warm starts the one --list-devices call of this process, in the
// background; further calls are no-ops, whatever bin they name.
func (p *gpuProbe) warm(bin string) {
	p.startOnce.Do(func() {
		go func() {
			defer close(p.done)
			ctx, cancel := context.WithTimeout(context.Background(), listDevicesTimeout)
			defer cancel()
			out, err := p.run(ctx, bin, "--list-devices")
			total, ok := parseListDevicesTotal(out)
			if err != nil || !ok {
				slog.Warn("notes fit: Metal memory total unavailable; the GPU fit check is skipped", "err", err, "parsed", ok)
				return
			}
			p.metal.Store(total)
		}()
	})
}

// limit is the Metal wired limit in bytes, 0 while unknown. It never starts
// or waits for the Metal call: warm does, at daemon start.
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
func (p *gpuProbe) wired() (limit, used uint64) {
	limit = p.limit()
	if limit == 0 {
		return 0, 0
	}
	used, ok := p.used()
	if !ok {
		return 0, 0
	}
	return limit, used
}
