//go:build !darwin

package player

import (
	"context"
	"fmt"
	"runtime"
)

// platformPlay has no macOS afplay off-darwin; the daemon targets Intel Macs
// and refuses cleanly elsewhere (tests stub Play).
func platformPlay(context.Context, string) error {
	return fmt.Errorf("audio playback is not supported on %s (afplay is macOS-only)", runtime.GOOS)
}
