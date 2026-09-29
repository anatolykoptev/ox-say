//go:build darwin

package player

import (
	"context"
	"os/exec"
)

// platformPlay uses macOS afplay — the same engine `say` uses.
func platformPlay(ctx context.Context, path string) error {
	return exec.CommandContext(ctx, "afplay", path).Run()
}
