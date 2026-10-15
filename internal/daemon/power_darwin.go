//go:build darwin

package daemon

import (
	"context"
	"os/exec"
	"time"

	"golang.org/x/sys/unix"
)

// Darwin's background priority (sys/resource.h; x/sys does not export them).
// PRIO_DARWIN_BG throttles CPU and disk I/O of the process; it does NOT
// govern GPU contention - the dictation yield (D12) does that part.
const (
	prioDarwinProcess = 4
	prioDarwinBG      = 0x1000
	pmsetPath         = "/usr/bin/pmset"
	pmsetTimeout      = 5 * time.Second
)

func setBackground(pid int, on bool) error {
	prio := 0
	if on {
		prio = prioDarwinBG
	}
	return unix.Setpriority(prioDarwinProcess, pid, prio)
}

// runPmset runs pmset with a short timeout.
func runPmset(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, pmsetTimeout)
	defer cancel()
	return exec.CommandContext(ctx, pmsetPath, args...).Output()
}
