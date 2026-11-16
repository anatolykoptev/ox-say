//go:build darwin

package meeting

import "golang.org/x/sys/unix"

// excludeFromBackup marks path (and, for a directory, everything under it) as left out of Time Machine and other
// backups. Meeting audio, transcripts and notes are private and the audio is deleted on a schedule, so none of it should
// sit on a backup disk. Reversible per path with `tmutil removeexclusion`.
func excludeFromBackup(path string) error {
	return unix.Setxattr(path, backupExcludeAttr, backupExcludeValue, 0)
}
