package engine

import (
	"errors"
	"strings"
)

// bootScopedToken joins the kernel boot identity and a boot-relative tick
// count into one whitespace-free start token. Linux's /proc/<pid>/stat
// starttime counts ticks since boot, so after a reboot a reused pid can carry
// the very tick count of the engine that died (#73); the boot id makes the
// two tokens differ. Platform-neutral so it is testable off Linux.
func bootScopedToken(bootID, ticks string) (string, error) {
	bootID = strings.TrimSpace(bootID)
	if bootID == "" {
		return "", errors.New("empty boot id")
	}
	if ticks == "" {
		return "", errors.New("empty start tick count")
	}
	return bootID + "-" + ticks, nil
}
