package daemon

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

const (
	// listenWait bounds how long the repair pass waits for the HTTP listener
	// before running anyway; listenPoll is the dial interval.
	listenWait = 60 * time.Second
	listenPoll = 100 * time.Millisecond
	// repairStopWait bounds how long Shutdown waits for a repair pass: Apply
	// is a handful of renames, so a pass in its critical section finishes in
	// milliseconds; the bound only guards a stuck re-registration.
	repairStopWait = 10 * time.Second
)

// voiceWords is the voice store's Transcriber: the daemon's own STT, word
// timestamps from the parakeet engine. A missing model is reported as
// voices.ErrNoTranscriber (a definitive "cannot"); every other failure is
// returned as is (busy, timeout, server down: transient).
func (d *Daemon) voiceWords(ctx context.Context, wavPath string) ([]voices.Word, error) {
	res, err := d.Transcribe(ctx, TranscribeInput{AudioPath: wavPath})
	if err != nil {
		var me *stt.ModelError
		if errors.As(err, &me) {
			return nil, fmt.Errorf("%w: %v", voices.ErrNoTranscriber, err)
		}
		return nil, err
	}
	out := make([]voices.Word, 0, len(res.Words))
	for _, w := range res.Words {
		out = append(out, voices.Word{W: w.W, S: w.S, E: w.E})
	}
	return out, nil
}

// StartVoiceRepair repairs stored voices whose transcript cannot match their
// audio, once per daemon start and off every request path. It waits for the
// HTTP listener first, so a bind failure ends the process before any voice
// is touched. A repaired voice keeps its original pair as
// <name>.orig.wav/.json.
func (d *Daemon) StartVoiceRepair() {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	d.repairCancel, d.repairDone = cancel, done
	go func() {
		defer close(done)
		if !waitListening(ctx, d.Cfg.Addr) {
			return
		}
		d.RepairVoices(ctx)
	}()
}

// StopVoiceRepair cancels a running pass and waits (bounded) for it: Apply
// must not be cut off between its renames by process exit.
func (d *Daemon) StopVoiceRepair() {
	if d.repairCancel == nil {
		return
	}
	d.repairCancel()
	select {
	case <-d.repairDone:
	case <-time.After(repairStopWait):
		d.log.Warn("voice repair still running at shutdown")
	}
}

// waitListening polls addr until something accepts, up to listenWait; false
// when ctx ended first.
func waitListening(ctx context.Context, addr string) bool {
	deadline := time.Now().Add(listenWait)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, listenPoll)
		if err == nil {
			_ = c.Close()
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(listenPoll):
		}
	}
	return ctx.Err() == nil
}

// RepairVoices runs one repair pass over the store. A failure on one voice is
// logged and does not stop the others; /status is left unchanged on purpose
// (its JSON shape is a compatibility surface), so the log is the only trace
// of a voice that could not be repaired.
func (d *Daemon) RepairVoices(ctx context.Context) {
	list, err := d.Store.List()
	if err != nil {
		d.log.Warn("voice repair: list failed", slog.Any("error", err))
		return
	}
	for _, v := range list {
		if ctx.Err() != nil {
			return
		}
		d.repairVoice(ctx, v.Name)
	}
}

func (d *Daemon) repairVoice(ctx context.Context, name string) {
	r, err := d.Store.PrepareRepair(ctx, name)
	switch {
	case errors.Is(err, voices.ErrNoTranscriber):
		d.log.Warn("voice repair: speech-to-text unavailable; voice left as is", slog.String("voice", name))
		return
	case errors.Is(err, voices.ErrScript):
		d.log.Warn("voice repair: ref_text is not Latin or Cyrillic script, which the speech-to-text cannot re-derive; voice left as is",
			slog.String("voice", name), slog.Any("error", err))
		return
	case errors.Is(err, voices.ErrStillBroken):
		d.log.Warn("backup exists but voice still broken: "+name, slog.String("voice", name))
		return
	case err != nil:
		d.log.Warn("voice repair failed; voice left as is", slog.String("voice", name), slog.Any("error", err))
		return
	case r == nil:
		return
	}
	defer r.Discard()
	if r.Retry {
		d.log.Warn("backup exists but voice still broken: "+name+"; retrying the repair", slog.String("voice", name))
	}
	d.voiceMu.Lock()
	defer d.voiceMu.Unlock()
	if err := r.Apply(); err != nil {
		d.log.Warn("voice repair failed; voice left as is", slog.String("voice", name), slog.Any("error", err))
		return
	}
	d.log.Info("voice repaired: ref_text replaced with the transcript of the audio",
		slog.String("voice", name), slog.String("reason", r.Reason),
		slog.Float64("cut_s", r.Cut), slog.String("was", r.OldText), slog.String("now", r.NewText))
	g := d.Sup.Acquire()
	defer g.Release()
	if base, ok := d.Sup.LiveURL(); ok {
		if err := d.ec.RegisterVoice(ctx, base, name, d.Store.WAVPath(name), r.NewText); err != nil {
			d.log.Warn("voice repaired but engine registration failed; it will be replayed on next start",
				slog.String("voice", name), slog.Any("error", err))
		}
	}
}
