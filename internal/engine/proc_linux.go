//go:build linux

package engine

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// processExe returns the executable path of a live process via /proc.
func processExe(pid int) (string, error) {
	return os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
}

// processStartTime returns an opaque token identifying the process's start
// instant: /proc/<pid>/stat field 22, in clock ticks since boot. It is only
// ever compared to another read of the same function — writePidFile stamps
// it next to the pid, reapOrphan re-reads it — so no unit conversion is
// needed.
func processStartTime(pid int) (string, error) {
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return "", err
	}
	// The comm field (2) is parenthesized and may itself contain spaces and
	// ')' — split after the LAST ')' so field numbering stays fixed.
	i := bytes.LastIndexByte(data, ')')
	if i < 0 {
		return "", fmt.Errorf("/proc/%d/stat: malformed (no comm terminator)", pid)
	}
	// fields[0] here is stat field 3 (state); starttime is field 22,
	// index 19 of the remainder.
	fields := strings.Fields(string(data[i+1:]))
	if len(fields) <= 19 {
		return "", fmt.Errorf("/proc/%d/stat: short field list", pid)
	}
	return fields[19], nil
}
