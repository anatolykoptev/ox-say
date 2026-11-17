//go:build darwin

package meeting

import "golang.org/x/sys/unix"

// excludeFromBackup marks path (and, for a directory, everything under it) as left out of Time Machine and other
// backups. Only meeting AUDIO is marked (the channel files, which the app marks; work/; the aec output at publish):
// retention deletes it on a schedule and a backup would keep it. Transcripts, notes and manifests are the user's to
// keep and are not marked. Reversible per path with `tmutil removeexclusion`.
func excludeFromBackup(path string) error {
	return unix.Setxattr(path, backupExcludeAttr, backupExcludeValue, 0)
}
