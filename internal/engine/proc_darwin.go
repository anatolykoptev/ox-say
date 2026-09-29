//go:build darwin

package engine

import (
	"bytes"
	"fmt"

	"golang.org/x/sys/unix"
)

// processExe returns the real executable path of a live process via the
// KERN_PROCARGS2 sysctl: the buffer starts with an int32 argc, then the
// exec path NUL-terminated, then argv/env strings. `ps -o comm=` would only
// report argv[0], which a process can lie about — and a wrong answer here
// SIGKILLs an innocent process that reused the pid.
func processExe(pid int) (string, error) {
	buf, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", fmt.Errorf("kern.procargs2 %d: %w", pid, err)
	}
	if len(buf) <= 4 {
		return "", fmt.Errorf("kern.procargs2 %d: short buffer", pid)
	}
	rest := buf[4:] // skip int32 argc
	if i := bytes.IndexByte(rest, 0); i > 0 {
		return string(rest[:i]), nil
	}
	return "", fmt.Errorf("kern.procargs2 %d: no exec path", pid)
}
