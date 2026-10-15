//go:build darwin

package config

import "golang.org/x/sys/unix"

// readHostMemoryBytes is sysctl hw.memsize; 0 when the call fails.
func readHostMemoryBytes() uint64 {
	n, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return 0
	}
	return n
}
