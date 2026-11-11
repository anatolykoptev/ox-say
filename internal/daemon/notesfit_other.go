//go:build !darwin

package daemon

// notesGPUWiredSysctl: no Metal wired budget exists off Apple Silicon; the
// unknown answer makes the fit check a no-op (the same convention as the
// other memory gates).
func notesGPUWiredSysctl() (limit, used uint64) { return 0, 0 }
