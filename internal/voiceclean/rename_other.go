//go:build !linux && !darwin

package voiceclean

import "os"

// renameNoReplace has no atomic form on this platform: a check and a rename (the daemon runs on macOS and Linux, where
// the atomic one is used).
func renameNoReplace(old, new string) (err error, unsupported bool) {
	if _, serr := os.Lstat(new); serr == nil {
		return os.ErrExist, false
	}
	return os.Rename(old, new), false
}
