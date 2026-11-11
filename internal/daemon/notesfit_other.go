//go:build !darwin

package daemon

// No Metal budget exists off Apple Silicon; the unknown answer makes the fit
// check a no-op (the same convention as the other memory gates).
func defaultNotesGPUWired(string) (limit, used uint64) { return 0, 0 }
func notesGPUWarm(string)                              {}
