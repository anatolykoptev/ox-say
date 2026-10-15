package daemon

import (
	"context"
	"log/slog"
	"net/http"
	"time"
)

// Quiet window and starvation bound of the dictation yield (D12); vars so
// tests can shorten them.
var (
	interactiveQuiet = 3 * time.Second
	maxYield         = 120 * time.Second
	waitingAfter     = 2 * time.Second
	quietPoll        = 250 * time.Millisecond
)

// interactiveRoutes serve live dictation and speak-selection; Routes wraps
// each with d.interactive. The test iterates this list.
var interactiveRoutes = []string{
	"POST /v1/audio/speech",
	"POST /v1/audio/transcriptions",
	"POST /v1/audio/transcriptions/sessions",
	"POST /v1/audio/transcriptions/sessions/{id}/audio",
	"POST /v1/audio/transcriptions/sessions/{id}/finish",
	"DELETE /v1/audio/transcriptions/sessions/{id}",
}

// interactive counts a request in flight and stamps when it ends.
func (d *Daemon) interactive(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		d.inflight.Add(1)
		defer func() {
			d.lastInteractiveEnd.Store(time.Now().UnixNano())
			d.inflight.Add(-1)
		}()
		h(w, r)
	}
}

// waitQuiet blocks until nothing interactive is in flight and
// interactiveQuiet has passed since the last one ended; after waitingAfter
// it calls onWait once; after maxYield it gives up waiting (bound).
func (d *Daemon) waitQuiet(ctx context.Context, onWait func()) error {
	start, told := time.Now(), false
	for {
		since := time.Since(time.Unix(0, d.lastInteractiveEnd.Load()))
		if d.inflight.Load() == 0 && since >= interactiveQuiet {
			return nil
		}
		if waited := time.Since(start); waited >= maxYield {
			d.log.Info("produce wait", slog.String("reason", "dictation"), slog.Float64("waited_s", waited.Seconds()), slog.Bool("bound", true))
			return nil
		} else if !told && waited >= waitingAfter {
			onWait()
			told = true
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(quietPoll):
		}
	}
}
