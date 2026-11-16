//go:build !darwin

package daemon

// readMemoryPressure: there is no pressure level off macOS; unknown never holds anything back.
func readMemoryPressure() int { return 0 }
