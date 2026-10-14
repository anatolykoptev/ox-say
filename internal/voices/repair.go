package voices

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

// backupInfix marks <name>.orig.wav / <name>.orig.json, the untouched pair a
// repair leaves beside the voice. Voice names cannot contain a dot, so the
// infix never collides with a voice; List skips such files.
const backupInfix = ".orig"

// Repair is a computed fix for a stored voice whose transcript cannot match
// its audio. PrepareRepair does the slow part (STT, ffmpeg) with no live
// voice touched; Apply swaps the result in and must run under the caller's
// voice mutex.
type Repair struct {
	Name    string
	Reason  string // why the voice was judged broken
	OldText string
	NewText string
	Cut     float64 // seconds kept, 0 when the audio is left whole
	s       *Store
	tmp     string // trimmed clip, "" when the audio is left whole
}

// Diagnose says why v's transcript cannot match its clip of dur seconds, or
// "" when it can. A voice without a ref_text clones timbre only and has no
// transcript to mismatch.
func Diagnose(v Voice, dur float64) string {
	if v.RefText == "" {
		return ""
	}
	if dur >= MaxRefSeconds-capEpsilon {
		return fmt.Sprintf("clip is at the %.0f s cap, so its transcript likely runs past the audio", MaxRefSeconds)
	}
	if wps := WordsPerSecond(v.RefText, dur); wps > MaxPlausibleWordsPerSecond {
		return fmt.Sprintf("transcript implies %.1f words/s (limit %.1f)", wps, MaxPlausibleWordsPerSecond)
	}
	return ""
}

// PrepareRepair returns nil, nil for a voice that is healthy, has no
// ref_text, or was already repaired (its .orig backup exists — a repair never
// runs twice, so a transcript the STT itself finds too fast cannot loop).
func (s *Store) PrepareRepair(ctx context.Context, name string) (*Repair, error) {
	v, err := s.Get(name)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(s.backupPath(name, ".json")); err == nil {
		return nil, nil
	}
	dur, err := WAVSeconds(s.WAVPath(name))
	if err != nil {
		return nil, err
	}
	reason := Diagnose(*v, dur)
	if reason == "" {
		return nil, nil
	}
	if s.transcribe == nil {
		return nil, ErrNoTranscriber
	}
	words, err := s.transcribe(ctx, s.WAVPath(name))
	if err != nil {
		return nil, fmt.Errorf("voices: repair %s: transcribe: %w", name, err)
	}
	r := &Repair{Name: name, Reason: reason, OldText: v.RefText, s: s}
	if dur >= MaxRefSeconds-capEpsilon {
		cut, ok := PlanCut(words, MaxRefSeconds)
		if !ok {
			return nil, fmt.Errorf("voices: repair %s: no speech found", name)
		}
		r.NewText, r.Cut = cut.Text, cut.At
		if err := r.cutCopy(ctx); err != nil {
			return nil, err
		}
	} else {
		r.NewText = joinWords(words)
	}
	if r.NewText == "" {
		r.Discard()
		return nil, fmt.Errorf("voices: repair %s: transcript is empty", name)
	}
	return r, nil
}

func (r *Repair) cutCopy(ctx context.Context) error {
	f, err := os.CreateTemp(r.s.dir, ".normalize-repair-*.wav")
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	r.tmp = f.Name()
	_ = f.Close()
	if err := r.s.cutTo(ctx, r.s.WAVPath(r.Name), r.tmp, r.Cut); err != nil {
		r.Discard()
		return err
	}
	return nil
}

// Discard removes the repair's temporary clip.
func (r *Repair) Discard() {
	if r.tmp != "" {
		_ = os.Remove(r.tmp)
		r.tmp = ""
	}
}

func (s *Store) backupPath(name, ext string) string {
	return filepath.Join(s.dir, name+backupInfix+ext)
}

// Apply backs the original pair up (never overwriting an existing backup) and
// swaps the repaired voice in. It refuses when the stored ref_text changed
// since PrepareRepair read it — the voice was re-added meanwhile.
func (r *Repair) Apply() error {
	defer r.Discard()
	s := r.s
	v, err := s.Get(r.Name)
	if err != nil {
		return err
	}
	if v.RefText != r.OldText {
		return fmt.Errorf("voices: repair %s: voice changed while repairing", r.Name)
	}
	for _, ext := range []string{".wav", ".json"} {
		if err := copyExcl(filepath.Join(s.dir, r.Name+ext), s.backupPath(r.Name, ext)); err != nil {
			return err
		}
	}
	nv := Voice{Name: v.Name, RefText: r.NewText, Created: v.Created}
	meta, err := json.Marshal(nv)
	if err != nil {
		return err
	}
	metaTmp := filepath.Join(s.dir, ".normalize-repair-"+r.Name+".meta")
	if err := s.writeFile(metaTmp, meta, 0o644); err != nil {
		_ = os.Remove(metaTmp)
		return fmt.Errorf("voices: %w", err)
	}
	if r.tmp != "" {
		if err := os.Rename(r.tmp, s.WAVPath(r.Name)); err != nil {
			_ = os.Remove(metaTmp)
			return fmt.Errorf("voices: %w", err)
		}
		r.tmp = ""
	}
	if err := os.Rename(metaTmp, s.metaPath(r.Name)); err != nil {
		_ = os.Remove(metaTmp)
		return fmt.Errorf("voices: %w", err)
	}
	return nil
}

// copyExcl copies src to dst, leaving an existing dst untouched.
func copyExcl(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, st.Mode().Perm())
	if errors.Is(err, fs.ErrExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(dst)
		return fmt.Errorf("voices: %w", err)
	}
	return out.Close()
}
