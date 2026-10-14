package daemon

import (
	"context"
	"errors"
	"log/slog"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// voiceWords is the voice store's Transcriber: the daemon's own STT, word
// timestamps from the parakeet engine.
func (d *Daemon) voiceWords(ctx context.Context, wavPath string) ([]voices.Word, error) {
	res, err := d.Transcribe(ctx, TranscribeInput{AudioPath: wavPath})
	if err != nil {
		return nil, err
	}
	out := make([]voices.Word, 0, len(res.Words))
	for _, w := range res.Words {
		out = append(out, voices.Word{W: w.W, S: w.S, E: w.E})
	}
	return out, nil
}

// StartVoiceRepair repairs stored voices whose transcript cannot match their
// audio, once per daemon start and off every request path. A repaired voice
// keeps its original pair as <name>.orig.wav/.json, so a voice is repaired at
// most once.
func (d *Daemon) StartVoiceRepair() {
	ctx, cancel := context.WithCancel(context.Background())
	d.repairCancel = cancel
	go d.RepairVoices(ctx)
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
	if err != nil {
		if errors.Is(err, voices.ErrNoTranscriber) {
			d.log.Warn("voice repair: speech-to-text unavailable; voice left as is", slog.String("voice", name))
			return
		}
		d.log.Warn("voice repair failed; voice left as is", slog.String("voice", name), slog.Any("error", err))
		return
	}
	if r == nil {
		return
	}
	defer r.Discard()
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
