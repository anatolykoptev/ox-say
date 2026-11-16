//go:build darwin

package daemon

import "golang.org/x/sys/unix"

// readMemoryPressure is kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical. A read that fails
// is 0, which never holds anything back (the same fail-open as powerState).
func readMemoryPressure() int {
	v, err := unix.SysctlUint32("kern.memorystatus_vm_pressure_level")
	if err != nil {
		return 0
	}
	return int(v)
}
