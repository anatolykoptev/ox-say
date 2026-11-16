package meeting

import (
	"log/slog"
	"os"
	"path/filepath"
)

// backupExcludeValue is the extended-attribute value macOS itself writes when an item is excluded from backup
// (`tmutil addexclusion`, `URLResourceValues.isExcludedFromBackup`): a binary plist holding the string
// "com.apple.backupd". The bytes are the ones tmutil produced.
var backupExcludeValue = []byte{
	'b', 'p', 'l', 'i', 's', 't', '0', '0',
	0x5f, 0x10, 0x11, 'c', 'o', 'm', '.', 'a', 'p', 'p', 'l', 'e', '.', 'b', 'a', 'c', 'k', 'u', 'p', 'd',
	0x08,
	0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x1c,
}

// backupExcludeAttr is the extended attribute Time Machine and the other backup tools read.
const backupExcludeAttr = "com.apple.metadata:com_apple_backup_excludeItem"

// excludeBackup is excludeFromBackup behind a test seam.
var excludeBackup = excludeFromBackup

// MakeWorkDir makes a meeting's scratch directory (0700) and marks it excluded from backup. work/ holds clips of the
// meeting's audio and the diarizer's answer (voiceprints) for the length of a run; retention deletes it with the audio,
// so a backup must not keep a copy. Only audio is excluded (the files of retiredNames): the transcript, notes and
// manifest are kept for good and stay in the user's own backups. A failed mark is logged, never an error: a meeting
// that cannot be processed is a worse outcome than a backed-up scratch directory.
func MakeWorkDir(meetingDir string) (string, error) {
	work := filepath.Join(meetingDir, WorkDir)
	if err := os.MkdirAll(work, 0o700); err != nil {
		return "", err
	}
	if err := excludeBackup(work); err != nil {
		slog.Default().Warn("meeting: could not exclude the work directory from backup", "err", err)
	}
	return work, nil
}
