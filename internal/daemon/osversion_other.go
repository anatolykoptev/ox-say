//go:build !darwin

package daemon

// macOSMajor: there is no macOS here, so no version to gate on (the daemon only ships for macOS).
func macOSMajor() (int, bool) { return 0, false }
