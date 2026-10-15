package voices

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// backupInfix marks <name>.orig.wav / <name>.orig.json, the untouched pair a
// repair leaves beside the voice. Voice names cannot contain a dot, so the
// infix never collides with a voice; List skips such files.
const backupInfix = ".orig"

// ErrStillBroken is returned by PrepareRepair for a voice that already has a
// backup yet is still unhealthy and could not be improved: the backup is not
// proof of a good repair, so the caller should say so (once per start).
var ErrStillBroken = errors.New("voices: backup exists but voice still broken")

// ErrChanged is returned by Repair.Apply when the voice was re-added or
// edited between PrepareRepair and Apply.
var ErrChanged = errors.New("voices: voice changed while repairing")

// stamp identifies the stored files a repair was computed from.
type stamp struct {
	refText string
	created time.Time
	size    int64
	mtime   time.Time
}

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
	// Retry is set when a backup already existed: an earlier repair did not
	// complete (crash) or did not leave the voice healthy.
	Retry bool

	s          *Store
	tmp        string // trimmed clip, "" when the audio is left whole
	from       stamp  // main files at PrepareRepair time
	haveBackup bool   // .orig.json (the commit marker) exists
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

// source picks the files a repair derives from. With a complete backup whose
// text equals the main text, a previous repair died before rewriting the
// main files, so the backup holds the original audio (the main WAV may
// already be a cut). Otherwise the main files are the source.
func (s *Store) source(name string, v *Voice) (wav, text string, haveBackup bool) {
	wav, text = s.WAVPath(name), v.RefText
	raw, err := os.ReadFile(s.backupPath(name, ".json"))
	if err != nil {
		return wav, text, false
	}
	var bk Voice
	if json.Unmarshal(raw, &bk) != nil {
		return wav, text, false
	}
	if _, err := os.Stat(s.backupPath(name, ".wav")); err != nil {
		return wav, text, false
	}
	if bk.RefText == v.RefText {
		return s.backupPath(name, ".wav"), bk.RefText, true
	}
	return wav, text, true
}

func (a stamp) equal(b stamp) bool {
	return a.refText == b.refText && a.size == b.size && a.created.Equal(b.created) && a.mtime.Equal(b.mtime)
}

func (s *Store) stampOf(name string, v *Voice) (stamp, error) {
	st, err := os.Stat(s.WAVPath(name))
	if err != nil {
		return stamp{}, err
	}
	return stamp{v.RefText, v.Created, st.Size(), st.ModTime()}, nil
}

// PrepareRepair returns nil, nil for a voice that is healthy, has no
// ref_text, or whose transcript turns out to match its audio. A backup that
// exists is a marker of a COMPLETED repair only while the main files are
// healthy and differ from it; otherwise the repair is retried (from the
// backup when the main files still carry the original text). ErrScript means
// the ref_text is not Latin/Cyrillic/Greek and is left alone; ErrStillBroken that a
// retry changed nothing.
func (s *Store) PrepareRepair(ctx context.Context, name string) (*Repair, error) {
	v, err := s.Get(name)
	if err != nil {
		return nil, err
	}
	mainDur, err := WAVSeconds(s.WAVPath(name))
	if err != nil {
		return nil, err
	}
	srcWav, srcText, haveBackup := s.source(name, v)
	if haveBackup && srcWav == s.WAVPath(name) && Diagnose(*v, mainDur) == "" {
		return nil, nil // repaired earlier and healthy now
	}
	srcDur := mainDur
	if srcWav != s.WAVPath(name) {
		if srcDur, err = WAVSeconds(srcWav); err != nil {
			return nil, err
		}
	}
	reason := Diagnose(Voice{RefText: srcText}, srcDur)
	if reason == "" {
		return nil, nil
	}
	if Script(srcText) == "" {
		return nil, fmt.Errorf("voice %s: %w", name, ErrScript)
	}
	if s.transcribe == nil {
		return nil, ErrNoTranscriber
	}
	words, err := s.transcribe(ctx, srcWav)
	if err != nil {
		return nil, fmt.Errorf("voices: repair %s: transcribe: %w", name, err)
	}
	r := &Repair{Name: name, Reason: reason, OldText: v.RefText, s: s, Retry: haveBackup, haveBackup: haveBackup}
	if err := r.plan(ctx, srcWav, srcText, srcDur, words); err != nil {
		r.Discard()
		return nil, err
	}
	if r.NewText == "" { // the transcript matches the stored text: nothing to repair
		return nil, nil
	}
	if haveBackup && r.NewText == v.RefText && (r.Cut == 0 || srcWav == s.WAVPath(name) && mainDur-r.Cut < capEpsilon) {
		r.Discard()
		return nil, fmt.Errorf("voice %s: %w", name, ErrStillBroken)
	}
	if r.from, err = s.stampOf(name, v); err != nil {
		r.Discard()
		return nil, err
	}
	return r, nil
}

// plan fills NewText and Cut (and the trimmed clip) from the transcript words
// of the source clip. NewText stays empty when the stored text already matches.
func (r *Repair) plan(ctx context.Context, srcWav, srcText string, srcDur float64, words []Word) error {
	name := r.Name
	if !SameScript(srcText, joinWords(words)) {
		return fmt.Errorf("voice %s: the transcript's script differs from ref_text: %w", name, ErrScript)
	}
	if TranscriptMatches(srcText, joinWords(words)) {
		return nil // a correct transcript, e.g. an exact 20.0 s clip with its own text
	}
	if srcDur >= MaxRefSeconds-capEpsilon {
		cut, ok := PlanCut(words, MaxRefSeconds)
		if !ok {
			return fmt.Errorf("voices: repair %s: no speech found", name)
		}
		if !cut.Covers(words) {
			return fmt.Errorf("voices: repair %s: the transcript skips stretches of the audio", name)
		}
		r.NewText, r.Cut = cut.Text, cut.At
		return r.cutCopy(ctx, srcWav)
	}
	if len(words) == 0 || !(Cut{Last: len(words) - 1}).Covers(words) {
		return fmt.Errorf("voices: repair %s: the transcript skips stretches of the audio", name)
	}
	r.NewText = joinWords(words)
	return nil
}

func (r *Repair) cutCopy(ctx context.Context, srcWav string) error {
	f, err := os.CreateTemp(r.s.dir, ".normalize-repair-*.wav")
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	r.tmp = f.Name()
	_ = f.Close()
	if err := r.s.cutTo(ctx, srcWav, r.tmp, r.Cut); err != nil {
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

// Apply backs the original pair up and swaps the repaired voice in. Every
// file lands by write-to-temp then rename, so a crash leaves either the old
// file or the new one. Order is the recovery protocol: the backup WAV, then
// the backup JSON (the commit marker — only a complete backup counts), then
// the main WAV, then the main JSON. A crash anywhere leaves a state
// PrepareRepair converges from: no marker -> the main files are untouched;
// marker with main text still the original -> retry from the backup.
// Apply refuses when the voice changed since PrepareRepair read it.
func (r *Repair) Apply() error {
	defer r.Discard()
	s := r.s
	v, err := s.Get(r.Name)
	if err != nil {
		return err
	}
	cur, err := s.stampOf(r.Name, v)
	if err != nil {
		return err
	}
	if !cur.equal(r.from) {
		return fmt.Errorf("repair %s: %w", r.Name, ErrChanged)
	}
	if !r.haveBackup {
		for _, ext := range []string{".wav", ".json"} { // .json last: the marker
			if err := s.copyAtomic(filepath.Join(s.dir, r.Name+ext), s.backupPath(r.Name, ext)); err != nil {
				return err
			}
		}
	}
	// Start from the voice just read, so every field a repair does not own
	// (engine, style, designed_from, and any added later) survives it.
	nv := *v
	nv.RefText = r.NewText
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
		if err := s.rename(r.tmp, s.WAVPath(r.Name)); err != nil {
			_ = os.Remove(metaTmp)
			return fmt.Errorf("voices: %w", err)
		}
		r.tmp = ""
	}
	if err := s.rename(metaTmp, s.metaPath(r.Name)); err != nil {
		_ = os.Remove(metaTmp)
		return fmt.Errorf("voices: %w", err)
	}
	return nil
}

// copyAtomic copies src to dst through a .normalize-* temp file and a rename;
// SweepTemp clears the temp after a crash. An existing dst is replaced.
func (s *Store) copyAtomic(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	defer in.Close()
	out, err := os.CreateTemp(s.dir, ".normalize-orig-*")
	if err != nil {
		return fmt.Errorf("voices: %w", err)
	}
	tmp := out.Name()
	_, err = io.Copy(out, in)
	if err == nil {
		err = out.Sync()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(tmp, 0o644)
	}
	if err == nil {
		err = s.rename(tmp, dst)
	}
	if err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("voices: %w", err)
	}
	return nil
}
