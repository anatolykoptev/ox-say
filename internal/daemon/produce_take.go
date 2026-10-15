package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vproject"
	"github.com/anatolykoptev/ox-say/internal/vscript"
	"github.com/anatolykoptev/ox-say/internal/wordalign"
)

// Gate constants are provisional: F1-0 Step 4 calibrates them on the owner's
// good/bad labels (produce_calib_test.go prints the per-gate rates).
const (
	gateMaxSilenceSec = 1.5  // inside a trimmed take: a stall or a cut
	gateMaxWER        = 0.10 // and more than gateMinErrors
	gateMinErrors     = 1
	gateFloorDB       = -45.0
	lastAttemptCfg    = 1.6 // upstream long-form stability advice (VoxCPM usage guide)
	maxTakeAttempts   = 3
	takeKeyVersion    = 1
	takeKeyBytes      = 12
	takeFileMode      = 0o600
	roundScale        = 100 // durations and rates are stored to two decimals
	noteReason        = "note: "
	// asrUnknown is the token Parakeet emits for a sound it cannot spell (a
	// spoken dash, a breath). Scored as a word it is an insertion against a
	// script that has none; a real missing word still counts as a deletion.
	asrUnknown = "<unk>"
)

// renderParams is one typed VoxCPM2 request of the producer.
type renderParams struct {
	Text, Voice, Style, Mode string
	Seed                     int64
	Cfg                      float64
	Steps                    int
}

// body is the request the speech router takes: the same map an HTTP caller
// sends, so every adapter rule (voxSeed, voxSampling, voxCloneMode, the style
// tag) judges it. An empty Style sends no instructions.
func (p renderParams) body() map[string]any {
	b := map[string]any{
		fieldModel: config.TTSModelVoxCPM2, fieldInput: p.Text, fieldVoice: p.Voice,
		"clone_mode": p.Mode, fieldSeed: p.Seed, "cfg_value": p.Cfg, "inference_timesteps": p.Steps,
	}
	if p.Style != "" {
		b[fieldInstruct] = p.Style
	}
	return b
}

// voiceFacts is what the producer knows of the job's voice, read live.
type voiceFacts struct {
	Name, RefText, Style, SHA string
}

// voice is the stored voice as the adapter's rules take it.
func (f voiceFacts) voice() *voices.Voice {
	return &voices.Voice{Name: f.Name, RefText: f.RefText, Meta: voices.Meta{Style: f.Style}}
}

// producePorts is everything the producer needs from the daemon. Only
// the daemon-side wiring in produce_wire.go (F1-5) builds it from closures.
type producePorts interface {
	Render(ctx context.Context, p renderParams) (*synthOut, error)
	Hear(ctx context.Context, wavPath string) ([]voices.Word, error)
	Voice(name string) (voiceFacts, error)
	DefaultVoice(lang string) string
	Unavailable() string
	EngineID() (string, error)
	Normalize(ctx context.Context, in, out string, lufs, durSec float64) error
	Quiet(ctx context.Context, onWait func()) error
	Power(ctx context.Context) (onBattery, lowPower bool)
	Background(on bool)
	Home() string
	OutputRoot() string
}

// chunkClone is how one chunk is spoken, decided by the adapter's own rules:
// the effective style (the chunk's, else the job's, else the voice's) and
// whether clone_mode auto would continue the reference (ultimate).
func chunkClone(f voiceFacts, jobStyle string, c vscript.Chunk) (style string, ultimate bool, err error) {
	asked := c.Style
	if asked == "" {
		asked = jobStyle
	}
	v := f.voice()
	style, err = voxStyle(map[string]any{fieldInstruct: asked}, v)
	if err != nil {
		return "", false, err
	}
	ultimate, err = voxCloneMode(map[string]any{}, v, style, c.Spoken)
	return style, ultimate, err
}

// jobCloneMode applies plan D5: ultimate only when the adapter says ultimate
// for every chunk, else reference for all; it returns each chunk's effective
// style (empty in ultimate mode, where a style cannot apply).
func jobCloneMode(f voiceFacts, jobStyle string, chunks []vscript.Chunk) (mode string, styles []string, err error) {
	styles = make([]string, len(chunks))
	allUltimate := len(chunks) > 0
	for i, c := range chunks {
		style, ultimate, err := chunkClone(f, jobStyle, c)
		if err != nil {
			return "", nil, err
		}
		styles[i], allUltimate = style, allUltimate && ultimate
	}
	if allUltimate {
		return cloneUltimate, make([]string, len(chunks)), nil
	}
	return cloneReference, styles, nil
}

// takeSpec is every input that changes a take's audio; its hash names the file.
type takeSpec struct {
	V        int     `json:"v"`
	Engine   string  `json:"engine"` // audiocpp_server sha + model file name:size
	Voice    string  `json:"voice"`
	VoiceSHA string  `json:"voice_sha"`
	RefText  string  `json:"ref_text"`
	Mode     string  `json:"mode"`
	Style    string  `json:"style"` // effective; "" in ultimate mode
	Text     string  `json:"text"`  // spoken
	Seed     int64   `json:"seed"`
	Cfg      float64 `json:"cfg"`
	Steps    int     `json:"steps"`
}

func (s takeSpec) key() string {
	raw, _ := json.Marshal(s) // strings and numbers only: cannot fail
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:takeKeyBytes])
}

// basis is the key without seed and cfg: what makes a chunk's takes valid.
func (s takeSpec) basis() string {
	s.Seed, s.Cfg = 0, 0
	return s.key()
}

// attempt is the spec of automatic attempt a: seed + a (wrapped into the
// engine's 32-bit seed range, which voxSeed enforces); the last automatic
// attempt lowers cfg. Attempts past it (regenerate) keep the base cfg.
func (s takeSpec) attempt(a int) takeSpec {
	s.Seed = (s.Seed + int64(a)) % (int64(maxVoxSeed) + 1)
	if a == maxTakeAttempts-1 && s.Cfg > lastAttemptCfg {
		s.Cfg = lastAttemptCfg
	}
	return s
}

func (s takeSpec) params() renderParams {
	return renderParams{Text: s.Text, Voice: s.Voice, Style: s.Style, Mode: s.Mode, Seed: s.Seed, Cfg: s.Cfg, Steps: s.Steps}
}

// takeDetail is the sidecar of one take: what the manifest does not carry.
type takeDetail struct {
	Ref     vproject.TakeRef `json:"ref"`
	Heard   []voices.Word    `json:"heard"`
	Warning string           `json:"warning,omitempty"`
}

// taker renders, stores and gates takes in dir (<project>/takes).
type taker struct {
	ports producePorts
	dir   string
	quiet func(context.Context) error
}

// take returns the take of spec: from its sidecar when both files exist (no
// render, no transcription); re-gated when only the WAV exists (a crash
// between the two writes); else rendered. text is the chunk as written (the
// WER reference); rendered reports an engine call.
func (t *taker) take(ctx context.Context, spec takeSpec, text string, attempt int) (vproject.TakeRef, bool, error) {
	key := spec.key()
	wavPath, side := filepath.Join(t.dir, key+".wav"), filepath.Join(t.dir, key+".json")
	if d, err := readDetail(side); err == nil && d.Ref.Key == key {
		if _, err := os.Stat(wavPath); err == nil {
			return d.Ref, false, nil
		}
	}
	rendered, warning := false, ""
	if _, err := os.Stat(wavPath); err != nil {
		out, err := t.render(ctx, spec, wavPath)
		if err != nil {
			return vproject.TakeRef{}, false, err
		}
		rendered, warning = true, out.Warning
	}
	return t.gate(ctx, gateJob{spec: spec, text: text, attempt: attempt, wavPath: wavPath, side: side, rendered: rendered, warning: warning})
}

// render asks the engine for spec and stores the answer at wavPath. Only a
// voxcpm2 answer that decodes as audio is kept: a degraded qwen render or a
// broken WAV never becomes a take.
func (t *taker) render(ctx context.Context, spec takeSpec, wavPath string) (*synthOut, error) {
	if err := t.quiet(ctx); err != nil {
		return nil, err
	}
	out, err := t.ports.Render(ctx, spec.params())
	if err != nil {
		return nil, err
	}
	if out.Model != config.TTSModelVoxCPM2 {
		return nil, fmt.Errorf("produce: the take came from %s; long-form voiceover needs voxcpm2", out.Model)
	}
	clip, err := pcm.Decode(out.WAV)
	if err != nil {
		return nil, fmt.Errorf("produce: engine answer: %w", err)
	}
	if len(clip.S) == 0 {
		return nil, fmt.Errorf("produce: engine answer: no audio")
	}
	if err := vproject.WriteAtomic(wavPath, out.WAV, takeFileMode); err != nil {
		return nil, err
	}
	return out, nil
}

// gateJob is one stored take about to be gated and recorded.
type gateJob struct {
	spec          takeSpec
	text          string
	attempt       int
	wavPath, side string
	rendered      bool
	warning       string
}

func (t *taker) gate(ctx context.Context, g gateJob) (vproject.TakeRef, bool, error) {
	raw, err := os.ReadFile(g.wavPath)
	if err != nil {
		return vproject.TakeRef{}, g.rendered, err
	}
	clip, err := pcm.Decode(raw)
	if err != nil {
		return vproject.TakeRef{}, g.rendered, err
	}
	if err := t.quiet(ctx); err != nil {
		return vproject.TakeRef{}, g.rendered, err
	}
	heard, err := t.ports.Hear(ctx, g.wavPath)
	if err != nil {
		return vproject.TakeRef{}, g.rendered, fmt.Errorf("produce: transcribe a take: %w", err)
	}
	fails, errs, n := gateTake(g.text, clip, heard)
	reasons := append([]string{}, fails...)
	if g.warning != "" { // recorded, never a failure (#143.6)
		reasons = append(reasons, noteReason+g.warning)
	}
	ref := vproject.TakeRef{Key: g.spec.key(), Seed: g.spec.Seed, Attempt: g.attempt, Cfg: g.spec.Cfg,
		DurationS: round2(clip.Seconds()), WER: round2(float64(errs) / float64(max(1, n))),
		Passed: len(fails) == 0, Reasons: reasons}
	raw, err = json.Marshal(takeDetail{Ref: ref, Heard: heard, Warning: g.warning})
	if err == nil {
		err = vproject.WriteAtomic(g.side, raw, takeFileMode)
	}
	return ref, g.rendered, err
}

func readDetail(path string) (takeDetail, error) {
	var d takeDetail
	raw, err := os.ReadFile(path)
	if err == nil {
		err = json.Unmarshal(raw, &d)
	}
	if err == nil && !vproject.ValidKey(d.Ref.Key) {
		err = fmt.Errorf("produce: %s: bad take key", filepath.Base(path))
	}
	return d, err
}

// gateTake applies plan D8: inner silence, then the WER round trip. text is
// the chunk as written; heard is what the daemon's own STT made of the take.
func gateTake(text string, clip pcm.Clip, heard []voices.Word) (fails []string, errs, n int) {
	if s := clip.LongestSilence(gateFloorDB); s > gateMaxSilenceSec {
		fails = append(fails, fmt.Sprintf("%.1f s of silence inside the take", s))
	}
	parts := make([]string, 0, len(heard))
	for _, h := range heard {
		if h.W != asrUnknown {
			parts = append(parts, h.W)
		}
	}
	errs, n = wordalign.WER(text, strings.Join(parts, " "))
	if float64(errs) > gateMaxWER*float64(max(1, n)) && errs > gateMinErrors {
		fails = append(fails, fmt.Sprintf("the transcript differs from the text in %d of %d words", errs, n))
	}
	return fails, errs, n
}

func round2(x float64) float64 { return math.Round(x*roundScale) / roundScale }
