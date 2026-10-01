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

// processStartTime returns an opaque token identifying the process's start
// instant: kern.proc.pid's p_starttime rendered "<sec>.<usec>". It is only
// ever compared to another read of the same function — writePidFile stamps
// it next to the pid, reapOrphan re-reads it — so no unit conversion is
// needed.
func processStartTime(pid int) (string, error) {
	proc, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return "", fmt.Errorf("kern.proc.pid %d: %w", pid, err)
	}
	tv := proc.Proc.P_starttime
	return fmt.Sprintf("%d.%06d", tv.Sec, tv.Usec), nil
}
