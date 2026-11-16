//go:build !darwin

package meeting

// excludeFromBackup has no platform support off macOS; the daemon's data lives there only in tests.
func excludeFromBackup(string) error { return nil }
