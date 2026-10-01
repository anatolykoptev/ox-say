package cli

import (
	"context"
	"io"
	"log/slog"
	"os"
	"time"

	"github.com/anatolykoptev/ox-say/internal/daemon"
)

// The daemon logs to stderr, which the LaunchAgent points at
// ~/Library/Logs/ox-say/ox-say.log. launchd never rotates that file, so serve
// caps it itself: at start, which also bounds a crash loop that KeepAlive
// restarts every 10 s, and periodically while it runs.
const (
	serveLogMaxBytes = 10 << 20
	serveLogCapEvery = 10 * time.Minute
)

// newServeLogger returns the daemon's logger writing to f, after capping f
// once, and keeps capping it every interval until ctx ends.
func newServeLogger(ctx context.Context, f *os.File, maxBytes int64, every time.Duration) *slog.Logger {
	logger := slog.New(daemon.QuietSessionChunks(
		slog.NewTextHandler(f, &slog.HandlerOptions{Level: slog.LevelInfo})))
	if err := capLog(f, maxBytes); err != nil {
		logger.Warn("log cap", slog.Any("error", err))
	}
	go func() {
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if err := capLog(f, maxBytes); err != nil {
					logger.Warn("log cap", slog.Any("error", err))
				}
			}
		}
	}()
	return logger
}

// capLog empties f when it is a regular file larger than maxBytes; a pipe or
// terminal is left alone. launchd opens the log O_APPEND, so the next write
// lands at the new end. The seek covers a file opened without O_APPEND
// (`ox-say serve 2>log`), which would otherwise go on writing at the old
// offset behind a hole.
func capLog(f *os.File, maxBytes int64) error {
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Size() <= maxBytes {
		return nil
	}
	if err := f.Truncate(0); err != nil {
		return err
	}
	_, err = f.Seek(0, io.SeekStart)
	return err
}
