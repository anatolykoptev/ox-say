package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

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
	// reasonSilent is the gate reason of a take with no audible samples;
	// settle prefers any take without it.
	reasonSilent = "the take is silent"
)

// gateLimits are the thresholds gateTake applies; the zero value means
// defaultGate. A taker field, not only constants, so a recalibration is
// testable and a cache hit is re-judged against the current limits.
type gateLimits struct {
	MaxSilenceSec float64
	MaxWER        float64
	MinErrors     int
	FloorDB       float64
}

var defaultGate = gateLimits{MaxSilenceSec: gateMaxSilenceSec, MaxWER: gateMaxWER, MinErrors: gateMinErrors, FloorDB: gateFloorDB}

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
	// Normalize writes in at lufs to out; limited reports that the peak limiter
	// pulled the loudest peaks down hard (or the target was missed under the
	// true-peak ceiling).
	Normalize(ctx context.Context, in, out string, lufs, durSec float64) (limited bool, err error)
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
	ports  producePorts
	dir    string
	quiet  func(context.Context) error
	limits gateLimits // zero: defaultGate
}

func (t *taker) gateLimits() gateLimits {
	if t.limits == (gateLimits{}) {
		return defaultGate
	}
	return t.limits
}

// take returns the take of spec. The gate judges the take against spec.Text,
// the text the engine was asked to say (Chunk.Spoken), never the written text.
//   - sidecar and WAV exist: no render, no transcription; the verdict is
//     recomputed from the stored heard words and the WAV under the current
//     limits, so a recalibration is never frozen out by the cache;
//   - only the WAV exists (a crash between the two writes): transcribed and
//     gated, not rendered;
//   - else rendered. A stored WAV that does not decode, or holds no audio,
//     counts as absent: the cache heals by rendering again.
//
// rendered reports an engine call.
func (t *taker) take(ctx context.Context, spec takeSpec, attempt int) (vproject.TakeRef, bool, error) {
	key := spec.key()
	wavPath, side := filepath.Join(t.dir, key+".wav"), filepath.Join(t.dir, key+".json")
	clip, err := readClip(wavPath)
	if err == nil {
		if d, derr := readDetail(side); derr == nil && d.Ref.Key == key {
			ref, _ := t.verdict(spec, attempt, clip, d.Heard, d.Warning)
			return ref, false, nil
		}
	}
	rendered, warning := false, ""
	if err != nil {
		out, rerr := t.render(ctx, spec, wavPath)
		if rerr != nil {
			return vproject.TakeRef{}, false, rerr
		}
		rendered, warning = true, out.Warning
		if clip, err = readClip(wavPath); err != nil {
			return vproject.TakeRef{}, true, err
		}
	}
	return t.gate(ctx, gateJob{spec: spec, attempt: attempt, clip: clip, wavPath: wavPath, side: side, rendered: rendered, warning: warning})
}

// readClip decodes a stored take; a missing, corrupt or empty file is an error.
func readClip(path string) (pcm.Clip, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return pcm.Clip{}, err
	}
	clip, err := pcm.Decode(raw)
	if err != nil {
		return pcm.Clip{}, fmt.Errorf("produce: %s: %w", filepath.Base(path), err)
	}
	if len(clip.S) == 0 {
		return pcm.Clip{}, fmt.Errorf("produce: %s: no audio", filepath.Base(path))
	}
	return clip, nil
}

// verdict is the gate result of one take: the manifest ref and its sidecar.
// The plausibility warning is a recorded reason, never a failure (#143.6).
func (t *taker) verdict(spec takeSpec, attempt int, clip pcm.Clip, heard []voices.Word, warning string) (vproject.TakeRef, takeDetail) {
	fails, errs, n := gateWith(t.gateLimits(), spec.Text, clip, heard)
	reasons := append([]string{}, fails...)
	if warning != "" {
		reasons = append(reasons, noteReason+warning)
	}
	ref := vproject.TakeRef{Key: spec.key(), Seed: spec.Seed, Attempt: attempt, Cfg: spec.Cfg,
		DurationS: round2(clip.Seconds()), WER: round2(float64(errs) / float64(max(1, n))),
		Passed: len(fails) == 0, Reasons: reasons}
	return ref, takeDetail{Ref: ref, Heard: heard, Warning: warning}
}

// render asks the engine for spec and stores the answer at wavPath. Only a
// voxcpm2 answer that decodes as audio is kept: a degraded qwen render or a
// broken WAV never becomes a take.
func (t *taker) render(ctx context.Context, spec takeSpec, wavPath string) (*synthOut, error) {
	if err := t.quiet(ctx); err != nil {
		return nil, err
	}
	out, err := t.renderWithin(ctx, spec)
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

// Per-render deadline: the audio a text makes (estCharsPerSec) times a budget
// well above the measured warm real-time factor, plus slack for an engine that
// has to start, with a floor. A render that outlasts it is a wedged engine.
const (
	renderBudgetRTF  = 4.0
	renderSlack      = 60 * time.Second
	renderFloor      = 90 * time.Second
	errEngineTimeout = "the voice engine did not answer in time; check that it is running, then resume the project"
)

// renderDeadline is the longest one render of chars characters may take.
var renderDeadline = func(chars int) time.Duration {
	audio := time.Duration(float64(chars) / estCharsPerSec * renderBudgetRTF * float64(time.Second))
	return max(renderFloor, audio+renderSlack)
}

// renderWithin renders spec under ctx and the per-render deadline. The port
// is called in its own goroutine so even one that ignores its context cannot
// hold the job: the job fails in plain words and the late answer is dropped.
func (t *taker) renderWithin(ctx context.Context, spec takeSpec) (*synthOut, error) {
	rctx, cancel := context.WithTimeout(ctx, renderDeadline(utf8.RuneCountInString(spec.Text)))
	defer cancel()
	type answer struct {
		out *synthOut
		err error
	}
	got := make(chan answer, 1)
	go func() {
		out, err := t.ports.Render(rctx, spec.params())
		got <- answer{out, err}
	}()
	select {
	case a := <-got:
		if a.err != nil && rctx.Err() != nil && ctx.Err() == nil {
			return nil, errors.New(errEngineTimeout)
		}
		return a.out, a.err
	case <-rctx.Done():
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errors.New(errEngineTimeout)
	}
}

// gateJob is one stored take about to be gated and recorded.
type gateJob struct {
	spec          takeSpec
	attempt       int
	clip          pcm.Clip
	wavPath, side string
	rendered      bool
	warning       string
}

func (t *taker) gate(ctx context.Context, g gateJob) (vproject.TakeRef, bool, error) {
	// A cancel that arrives while waiting for quiet does not drop a take that
	// is already rendered: the wait is skipped and the take is gated and kept.
	if err := t.quiet(ctx); err != nil && !errors.Is(err, errCancelled) {
		return vproject.TakeRef{}, g.rendered, err
	}
	heard, err := t.ports.Hear(ctx, g.wavPath)
	if err != nil {
		return vproject.TakeRef{}, g.rendered, fmt.Errorf("produce: transcribe a take: %w", err)
	}
	ref, detail := t.verdict(g.spec, g.attempt, g.clip, heard, g.warning)
	raw, err := json.Marshal(detail)
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

// gateTake applies plan D8 with the default limits.
func gateTake(spoken string, clip pcm.Clip, heard []voices.Word) (fails []string, errs, n int) {
	return gateWith(defaultGate, spoken, clip, heard)
}

// gateWith applies plan D8: a silent take, inner silence, then the WER round
// trip. spoken is the text the engine was asked to say (Chunk.Spoken); heard
// is what the daemon's own STT made of the take.
//
// Parakeet writes <unk> for a spoken dash or breath, so <unk> tokens are
// dropped from the transcript, but only as many as the spoken text has dashes
// and punctuation marks: each one past that is a word the take got wrong,
// else a babbled tail of <unk> would score as clean.
func gateWith(l gateLimits, spoken string, clip pcm.Clip, heard []voices.Word) (fails []string, errs, n int) {
	if voiced, _ := clip.Trim(l.FloorDB, 0); len(voiced.S) == 0 {
		fails = append(fails, reasonSilent)
	}
	if s := clip.LongestSilence(l.FloorDB); s > l.MaxSilenceSec {
		fails = append(fails, fmt.Sprintf("%.1f s of silence inside the take", s))
	}
	parts := make([]string, 0, len(heard))
	unknown := 0
	for _, h := range heard {
		if h.W == asrUnknown {
			unknown++
			continue
		}
		parts = append(parts, h.W)
	}
	errs, n = wordalign.WER(spoken, strings.Join(parts, " "))
	errs += max(0, unknown-countPunct(spoken))
	if float64(errs) > l.MaxWER*float64(max(1, n)) && errs > l.MinErrors {
		fails = append(fails, fmt.Sprintf("the transcript differs from the text in %d of %d words", errs, n))
	}
	return fails, errs, n
}

// countPunct is the number of dash and punctuation marks in s.
func countPunct(s string) int {
	n := 0
	for _, r := range s {
		if unicode.IsPunct(r) {
			n++
		}
	}
	return n
}

func round2(x float64) float64 { return math.Round(x*roundScale) / roundScale }
