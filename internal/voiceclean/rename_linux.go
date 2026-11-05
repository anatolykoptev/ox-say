//go:build linux

package voiceclean

import "golang.org/x/sys/unix"

// renameNoReplace moves old to new unless new exists (renameat2 RENAME_NOREPLACE: one atomic step, no window between
// the check and the move). The error is EEXIST when new is there; unsupported is true on a filesystem without it.
func renameNoReplace(old, new string) (err error, unsupported bool) {
	err = unix.Renameat2(unix.AT_FDCWD, old, unix.AT_FDCWD, new, unix.RENAME_NOREPLACE)
	return err, err == unix.EINVAL || err == unix.ENOSYS || err == unix.ENOTSUP
}
