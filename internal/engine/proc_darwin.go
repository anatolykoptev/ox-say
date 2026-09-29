//go:build darwin

package engine

import (
	"os/exec"
	"strconv"
	"strings"
)

// processExe returns the executable path of a live process. On macOS
// `ps -o comm=` prints the full path the process was exec'd with.
func processExe(pid int) (string, error) {
	out, err := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}
