//go:build darwin

package daemon

import "golang.org/x/sys/unix"

// wiredLimitMB reads iogpu.wired_limit_mb: 0 on a stock Mac (the system
// default), non-zero only when someone set it. The kernel's width for this
// oid is not documented, so both are tried.
func wiredLimitMB() uint64 {
	if v, err := unix.SysctlUint64("iogpu.wired_limit_mb"); err == nil {
		return v
	}
	if v, err := unix.SysctlUint32("iogpu.wired_limit_mb"); err == nil {
		return uint64(v)
	}
	return 0
}

var realGPUProbe = newGPUProbe(wiredLimitMB, execRun)

// defaultNotesGPUWired and notesGPUWarm are the darwin probe (see
// notesfit_probe.go for where each figure comes from).
func defaultNotesGPUWired(string) (limit, used uint64) { return realGPUProbe.wired() }
func notesGPUWarm(bin string) {
	if wiredLimitMB() == 0 { // an explicit limit makes the Metal call moot
		realGPUProbe.warm(bin)
	}
}
