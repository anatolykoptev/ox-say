//go:build darwin

package daemon

import "golang.org/x/sys/unix"

// notesGPUWiredSysctl reads the Metal wired budget on Apple Silicon:
// iogpu.wired_limit_mb is the ceiling the GPU heap may wire — the number the
// emulated-memory runs measure against — and iogpu.wired_allocated_mb is
// what is wired right now, the daemon's own engines and every other client
// included. Both are megabytes; (0,0) reports a Mac that answers nothing.
func notesGPUWiredSysctl() (limit, used uint64) {
	limit, _ = unix.SysctlUint64("iogpu.wired_limit_mb")
	used, _ = unix.SysctlUint64("iogpu.wired_allocated_mb")
	return limit << 20, used << 20
}
