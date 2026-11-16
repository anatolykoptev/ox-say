//go:build darwin

package daemon

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/meeting"
	"golang.org/x/sys/unix"
)

// The diarizer writes its answer (voiceprints) into work/, and a run can reach that directory before transcription
// made it: runDiarizer makes it through meeting.MakeWorkDir, so it carries the backup exclusion. The attribute name is
// the one `tmutil addexclusion` writes, spelled out here as the oracle.
// Mutation: diarize.go runDiarizer, `meeting.MakeWorkDir(filepath.Dir(pcmPath))` -> `filepath.Join(filepath.Dir(pcmPath),
// meeting.WorkDir)` plus an `os.MkdirAll(work, 0o700)` -> RED ("work/ is not excluded from backup").
func TestTheDiarizersWorkDirectoryIsExcludedFromBackup(t *testing.T) {
	cfg, pcm := stubDiar(t, `printf '{}' > "$2"`)
	if _, err := runDiarizer(context.Background(), cfg, pcm); err != nil {
		t.Fatal(err)
	}
	work := filepath.Join(filepath.Dir(pcm), meeting.WorkDir)
	if _, err := unix.Getxattr(work, "com.apple.metadata:com_apple_backup_excludeItem", make([]byte, 128)); err != nil {
		t.Fatalf("work/ is not excluded from backup: %v", err)
	}
}
