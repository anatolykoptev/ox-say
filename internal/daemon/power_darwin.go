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

// powerState reads pmset (read-only): on battery, and Low Power Mode. A
// failure reads as "on AC, normal" so a broken pmset never blocks a job.
func powerState(ctx context.Context) (onBattery, lowPower bool) {
	ctx, cancel := context.WithTimeout(ctx, pmsetTimeout)
	defer cancel()
	batt, err := exec.CommandContext(ctx, pmsetPath, "-g", "batt").Output()
	if err != nil {
		return false, false
	}
	all, _ := exec.CommandContext(ctx, pmsetPath, "-g").Output()
	return parsePower(string(batt), string(all))
}
