package meeting

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// minDiarWords: a far side that said fewer words has nothing to tell apart.
const minDiarWords = 20

// voiceResult is the diarizer's contribution to one transcription.
type voiceResult struct {
	of     map[[2]float64]string // word (start, end) -> "them:<n>"
	mode   string
	voices int
	warn   string // WarnNoDiarization or WarnDiarUnavailable, "" when voices were told apart or none were looked for
	reason string // Manifest.DiarReason
}

// voices tells the far side's speakers apart. It never fails the meeting: a Mac that cannot run the diarizer
// (Deps.DiarizeReady) leaves one far-side label and WarnDiarUnavailable; a diarizer that breaks leaves it and
// WarnNoDiarization; both carry a reason code. Only a daemon shutdown (ctx) is an error, so the meeting resumes.
// The embeddings in ox-diar's answer are used here and dropped: nothing of them reaches the meeting directory
// outside work/, where the daemon wrote them for the length of the call.
func (r *Runner) voices(ctx context.Context, dir string, words []stt.Word) (voiceResult, error) {
	if r.Diarize == nil || len(words) < minDiarWords {
		return voiceResult{}, nil
	}
	if r.DiarizeReady != nil {
		if code := r.DiarizeReady(); code != "" {
			r.Log.Info("meeting: diarization unavailable", slog.String("reason", code))
			return voiceResult{warn: WarnDiarUnavailable, reason: code}, nil
		}
	}
	if r.Before != nil {
		if err := r.Before(ctx); err != nil {
			return voiceResult{}, err
		}
	}
	raw, err := r.Diarize(ctx, filepath.Join(dir, ThemPCM))
	if ctx.Err() != nil {
		return voiceResult{}, ctx.Err()
	}
	var unavailable *DiarUnavailableError
	if errors.As(err, &unavailable) {
		r.Log.Info("meeting: diarization unavailable", slog.String("reason", unavailable.Reason), slog.Any("error", err))
		return voiceResult{warn: WarnDiarUnavailable, reason: unavailable.Reason}, nil
	}
	reason := DiarEngineError
	var d *Diarization
	if err == nil {
		if d, err = ParseDiarization(raw); err != nil {
			reason = DiarBadOutput
		}
	} else if errors.Is(err, context.DeadlineExceeded) {
		reason = DiarTimeout
	}
	if err != nil {
		r.Log.Warn("meeting: diarization failed", slog.String("reason", reason), slog.Any("error", err))
		return voiceResult{warn: WarnNoDiarization, reason: reason}, nil
	}
	if err := dropVoiceState(dir); err != nil {
		return voiceResult{}, err
	}
	plan := Decide(d)
	res := voiceResult{mode: plan.Mode, voices: plan.Voices}
	if plan.Mode == "" {
		return res, nil
	}
	res.of = map[[2]float64]string{}
	for i, v := range AssignVoices(words, d, plan) {
		res.of[[2]float64{words[i].S, words[i].E}] = v
	}
	return res, nil
}

// dropVoiceState forgets what the user decided about the voices of an earlier diarization: a new one numbers
// the voices again, so "them:2" no longer means the same person. The name of the single far-side label stays.
// An unreadable speakers.json is removed: its ids cannot be trusted either.
func dropVoiceState(dir string) error {
	st, err := LoadSpeakers(dir)
	if err != nil {
		if rerr := os.Remove(filepath.Join(dir, SpeakersJSON)); rerr != nil && !errors.Is(rerr, os.ErrNotExist) {
			return rerr
		}
		return nil
	}
	keep := SpeakerState{}
	if n := st.Names[SpeakerThem]; n != "" {
		keep.Names = map[string]string{SpeakerThem: n}
	}
	return SaveSpeakers(dir, keep)
}
