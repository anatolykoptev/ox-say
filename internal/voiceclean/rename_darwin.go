//go:build darwin

package voiceclean

import "golang.org/x/sys/unix"

// renameNoReplace moves old to new unless new exists (renamex_np RENAME_EXCL: one atomic step, no window between the
// check and the move). The error is EEXIST when new is there; unsupported is true on a filesystem without it.
func renameNoReplace(old, new string) (err error, unsupported bool) {
	err = unix.RenamexNp(old, new, unix.RENAME_EXCL)
	return err, err == unix.ENOTSUP || err == unix.EINVAL || err == unix.ENOSYS
}
