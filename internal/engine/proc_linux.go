//go:build linux

package engine

import (
	"os"
	"strconv"
)

// processExe returns the executable path of a live process via /proc.
func processExe(pid int) (string, error) {
	return os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
}
