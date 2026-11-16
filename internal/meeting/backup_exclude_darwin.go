//go:build darwin

package meeting

import "golang.org/x/sys/unix"

// excludeFromBackup marks path (and, for a directory, everything under it) as left out of Time Machine and other
// backups: meeting audio is private and is deleted on a schedule, so it must not outlive that on a backup disk.
func excludeFromBackup(path string) error {
	return unix.Setxattr(path, backupExcludeAttr, backupExcludeValue, 0)
}
