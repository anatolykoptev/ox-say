//go:build !darwin

package config

// readHostMemoryBytes: VoxCPM2 only runs on macOS, where the real probe lives;
// 0 means "unknown" and never blocks.
func readHostMemoryBytes() uint64 { return 0 }
