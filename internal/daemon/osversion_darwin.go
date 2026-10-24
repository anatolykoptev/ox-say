//go:build darwin

package daemon

import (
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// macOSMajor is the major version of the running macOS ("15.7.9" -> 15); false when the system will not say.
func macOSMajor() (int, bool) {
	v, err := unix.Sysctl("kern.osproductversion")
	if err != nil {
		return 0, false
	}
	major, _, _ := strings.Cut(strings.TrimSpace(v), ".")
	n, err := strconv.Atoi(major)
	return n, err == nil
}
