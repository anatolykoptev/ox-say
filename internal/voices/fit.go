package voices

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ffmpegTimeout bounds one ffmpeg normalisation or cut.
const ffmpegTimeout = 60 * time.Second

// ErrNoTranscriber is returned by PrepareRepair when the store has no
// word-timestamp source.
var ErrNoTranscriber = errors.New("voices: no transcriber configured")

// tooLongMsg is the refusal for a clip that outruns the cap when its
// transcript cannot be re-derived.
func tooLongMsg(why string) string {
	return fmt.Sprintf("voices: clip is longer than %.0f s and cannot be matched to its ref_text (%s) — trim it or pass a clip of at most %.0f s",
		MaxRefSeconds, why, MaxRefSeconds)
}

// scriptMsg refuses a too-long clip whose ref_text the STT cannot reproduce:
// replacing the user's own transcript with a transliteration would be worse
// than the cap.
const scriptMsg = "voices: clip is longer than 20 s and its ref_text is not in Latin, Cyrillic or Greek script, which the speech-to-text cannot re-derive — trim the clip to at most 20 s and keep your own transcript"

// fitReference makes the clip at wav and its transcript describe the same
// audio. A clip within the cap keeps refText as given. A longer one without a
// ref_text is simply cut at the cap (nothing to mismatch). A longer one WITH a
// ref_text is transcribed, cut at a word boundary within the cap, and the
// returned text is the transcript of the kept part; notice then says so. A
// longer clip that cannot be transcribed is refused — storing it would pair a
// transcript with audio that was cut off, which makes the model speak the
// reference's continuation instead of the request.
func (s *Store) fitReference(ctx context.Context, wav, refText string) (text, notice string, err error) {
	dur, err := WAVSeconds(wav)
	if err != nil {
		return "", "", fmt.Errorf("voices: %w", err)
	}
	if dur <= MaxRefSeconds+capEpsilon {
		return refText, "", nil
	}
	if refText == "" {
		return "", "", s.trimWAV(ctx, wav, MaxRefSeconds)
	}
	if Script(refText) == "" {
		return "", "", &InputError{scriptMsg}
	}
	if s.transcribe == nil {
		return "", "", &InputError{tooLongMsg("speech-to-text is unavailable")}
	}
	words, err := s.transcribe(ctx, wav)
	switch {
	case errors.Is(err, ErrNoTranscriber):
		return "", "", &InputError{tooLongMsg("speech-to-text is unavailable")}
	case err != nil:
		// Busy, timed out, server down: transient, not the caller's input.
		return "", "", fmt.Errorf("voices: clip is longer than %.0f s and speech-to-text failed (retry, or trim the clip to at most %.0f s): %w",
			MaxRefSeconds, MaxRefSeconds, err)
	}
	cut, ok := PlanCut(words, MaxRefSeconds)
	if !ok || cut.Text == "" {
		return "", "", &InputError{tooLongMsg("no speech found in the first 20 s")}
	}
	if !cut.Covers(words) {
		return "", "", &InputError{tooLongMsg("the transcript skips stretches of the audio")}
	}
	if !SameScript(refText, cut.Text) {
		return "", "", &InputError{scriptMsg}
	}
	if err := s.trimWAV(ctx, wav, cut.At); err != nil {
		return "", "", err
	}
	notice = fmt.Sprintf("clip is longer than %.0f s: kept the first %.1f s and replaced ref_text with its %d-word transcript",
		MaxRefSeconds, cut.At, cut.Last+1)
	return cut.Text, notice, nil
}

// trimWAV rewrites wav in place keeping its first sec seconds.
func (s *Store) trimWAV(ctx context.Context, wav string, sec float64) error {
	out, err := os.CreateTemp(s.dir, ".normalize-cut-*.wav")
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	outName := out.Name()
	_ = out.Close()
	defer os.Remove(outName) // no-op after the rename below
	if err := s.cutTo(ctx, wav, outName, sec); err != nil {
		return err
	}
	if err := os.Rename(outName, wav); err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	return nil
}

// cutTo writes the first sec seconds of src to dst as 24 kHz mono s16 WAV.
func (s *Store) cutTo(ctx context.Context, src, dst string, sec float64) error {
	ctx, cancel := context.WithTimeout(ctx, ffmpegTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, s.ffmpeg,
		"-hide_banner", "-loglevel", "error", "-y",
		"-i", src,
		"-t", fmt.Sprintf("%.3f", sec),
		"-ar", fmt.Sprint(RefSampleRate), "-ac", "1", "-c:a", "pcm_s16le",
		dst,
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("voices: ffmpeg cut: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
