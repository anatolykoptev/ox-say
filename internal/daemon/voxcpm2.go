package daemon

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

const (
	voxcpm2ServerFile = "voxcpm2-server.json"
	// voxLoopbackHost is the only address the child binds and the daemon
	// dials. audio.cpp's loopback guard (patch 0002) refuses "localhost" and
	// "[::1]" as Host headers, so a name or an IPv6 literal would be refused
	// (issue #137.3).
	voxLoopbackHost = "127.0.0.1"
	// voxStartupTimeout is the child's start budget: measured 8 s for the
	// first-ever start (6.2 s of it the Metal library compile), 1.2–2 s after.
	voxStartupTimeout = 30 * time.Second
	// voxBusyTimeoutMS bounds a queued request behind a wedged GPU call in
	// audiocpp_server (its own guard, README "busy_timeout_ms"): 10 minutes
	// covers a 1000-character line at RTF ~1 several times over.
	voxBusyTimeoutMS = 600000
	// voxPromptCacheSlots keeps the encoded references of this many voices
	// warm in the engine, so a script alternating voices is not re-encoding.
	// The key needs the "voxcpm2." prefix: session.cpp:148-156 reads only that,
	// and an unprefixed key is skipped silently.
	voxPromptCacheSlots = 8
	// voxEncoderSampleCapacity is the AudioVAE encoder's reference window in
	// samples at 16 kHz: 30 s. The engine default, 240000 (15 s), answers
	// HTTP 500 on a 17 s reference voice.
	voxEncoderSampleCapacity = 480000
	// voxEncoderSampleRate is the rate voxEncoderSampleCapacity counts in.
	voxEncoderSampleRate = 16000
	// voxMaxRefSeconds is the longest reference clip the encoder takes (30 s),
	// derived so it cannot drift from the capacity above.
	voxMaxRefSeconds = voxEncoderSampleCapacity / voxEncoderSampleRate
	// voxMaxBodyBytes caps a request body (audio.cpp's default is 2 GiB); the
	// daemon sends JSON with file paths, never inline audio.
	voxMaxBodyBytes = 8 << 20
	// voxMinFreeMB makes the engine answer 503 instead of pushing the Mac into
	// swap, which would stall dictation.
	voxMinFreeMB = 2048
	// voxThreads is the engine's CPU thread count: the sweep measured no gain
	// above one with the Metal backend. mem_saver stays at its default —
	// turning it off costs 1.3 GB for no speed.
	voxThreads = 1
)

// voxcpm2ServerConfig is audiocpp_server's --config for one offline VoxCPM2
// model on loopback (shape verified against the real server in the engine
// gate). It never sets log_request_body, so input text stays out of the log.
func voxcpm2ServerConfig(cfg *config.Config, port int) map[string]any {
	return map[string]any{
		"host": voxLoopbackHost, "port": port, "backend": "metal", "threads": voxThreads,
		"lazy_load": false, "busy_timeout_ms": voxBusyTimeoutMS,
		"max_request_body_bytes": voxMaxBodyBytes, "min_free_memory_mb": voxMinFreeMB,
		"models": []map[string]any{{
			"id": config.TTSModelVoxCPM2, "family": "voxcpm2", "path": cfg.VoxCPM2Model,
			"task": "tts", "mode": "offline",
			"session_options": map[string]any{
				"voxcpm2.prompt_cache_slots":               voxPromptCacheSlots,
				"voxcpm2.audiovae_encoder_sample_capacity": voxEncoderSampleCapacity,
			},
		}},
	}
}

// voxcpm2ServerArgs writes the server config for port into the run dir and
// returns the child's argv. It runs at every spawn, so a config change applies
// on the next start. A write failure is logged; the child then fails its start
// and the supervisor reports it.
//
// The argv never carries --parallel-jobs: that server path has neither the
// loopback Host guard nor prompt_audio (issue #137.1). It never carries --log,
// which would put input text into voxcpm2.log.
func voxcpm2ServerArgs(cfg *config.Config, port int, log *slog.Logger) []string {
	path := filepath.Join(cfg.RunDir(), voxcpm2ServerFile)
	raw, err := json.MarshalIndent(voxcpm2ServerConfig(cfg, port), "", "  ")
	if err == nil {
		err = os.WriteFile(path, raw, 0o644)
	}
	if err != nil {
		log.Error("voxcpm2: cannot write server config", slog.String("path", path), slog.Any("error", err))
	}
	return []string{"--config", path, "--no-ui"}
}

// newVoxSupervisor builds the voxcpm2 child's supervisor (audiocpp_server).
// Only on unified memory: on a discrete card the 2B model cannot fit next to
// the speech engines (config.VoxCPM2Unavailable). The child holds ~4 GB while
// loaded, so IdleStop returns it to zero when VoxCPM2 is unused.
func newVoxSupervisor(cfg *config.Config, logger *slog.Logger, tune func(*engine.Config)) (*engine.Supervisor, error) {
	vc := engine.Config{
		Name:           config.TTSModelVoxCPM2,
		Bin:            cfg.VoxCPM2Bin,
		Port:           cfg.VoxCPM2Port,
		StartupTimeout: voxStartupTimeout,
		IdleStop:       cfg.IdleStop,
		LogName:        "voxcpm2.log",
		LogDir:         cfg.EngineLogDir,
		PidPath:        filepath.Join(cfg.RunDir(), "voxcpm2.pid"),
		Logger:         logger,
		Args:           func(port int) []string { return voxcpm2ServerArgs(cfg, port, logger) },
	}
	if tune != nil {
		tune(&vc)
	}
	return engine.New(vc)
}

// voxCPM2Status is the /status "voxcpm2" value, shaped for a UI that shows a
// non-technical person one of: unavailable (with Reason), stopped, starting,
// ready, crashed. Available is false exactly when State is "unavailable".
type voxCPM2Status struct {
	Available bool         `json:"available"`
	Reason    string       `json:"reason,omitempty"`
	State     engine.State `json:"state"`
	PID       int          `json:"pid,omitempty"`
	BaseURL   string       `json:"base_url,omitempty"`
	UptimeS   float64      `json:"uptime_s,omitempty"`
	LastErr   string       `json:"last_error,omitempty"`
	Starts    int          `json:"starts"`
	Restarts  int          `json:"restarts"`
}

// stateVoxUnavailable is the State of an engine that cannot run on this host.
const stateVoxUnavailable engine.State = "unavailable"

// voxStatus reports the voxcpm2 engine for /status.
func (d *Daemon) voxStatus() voxCPM2Status {
	if reason := d.voxUnavailable(); reason != "" {
		return voxCPM2Status{State: stateVoxUnavailable, Reason: reason}
	}
	st := d.VoxSup.Status()
	return voxCPM2Status{
		Available: true, State: st.State, PID: st.PID, BaseURL: st.BaseURL,
		UptimeS: st.UptimeS, LastErr: st.LastErr, Starts: st.Starts, Restarts: st.Restarts,
	}
}

const (
	// maxVoxChars is the per-request input cap on voxcpm2: about 75 s of speech.
	// Longer scripts belong to the long-form producer (plan F1).
	maxVoxChars = 1000
	// Plausibility budget: fixed slack plus the input at half the slowest
	// measured Russian pace (~10.7 chars/s for a sad design line, 12-16 chars/s
	// typical, plan §1.6 S3), i.e. >= 1.8x headroom. It only DETECTS; the engine
	// bounds generation itself (plan D8).
	budgetBaseSec     = 3.0
	budgetCharsPerSec = 6.0
	// The engine's runaway guard, at the upstream defaults the owner's A/B ran
	// with (audio.cpp include/engine/models/voxcpm2/types.h).
	voxRetryTimes    = 3
	voxRetryRatio    = 6.0
	defaultCfgValue  = 2.0
	maxCfgValue      = 5.0
	defaultTimesteps = 10
	maxTimesteps     = 50
	// maxVoxSeed is the largest seed the engine takes (an unsigned 32-bit int).
	maxVoxSeed = math.MaxUint32

	cloneAuto      = "auto"
	cloneReference = "reference"
	cloneUltimate  = "ultimate"
)

// voxReq is one VoxCPM2 engine request and what the daemon checks on its answer.
type voxReq struct {
	body      map[string]any
	budgetSec float64
	seed      int64
}

// lengthBudget is the longest plausible speech for text, in seconds.
func lengthBudget(text string) float64 {
	return budgetBaseSec + float64(utf8.RuneCountInString(text))/budgetCharsPerSec
}

// buildVoxCPM2 maps a prepared speech body and its resolved voice (nil = no
// voice: zero-shot, or voice design when a style is set) onto
// audiocpp_server's VoxCPM2 dialect (plan §1.5). The only place the dialect's
// literals live.
func buildVoxCPM2(body map[string]any, v *voices.Voice, wavPath string) (*voxReq, error) {
	input, _ := body[fieldInput].(string)
	if n := utf8.RuneCountInString(input); n > maxVoxChars {
		return nil, &requestError{fmt.Sprintf("voxcpm2 takes up to %d characters per request (got %d): split the script at sentence ends, or use the long-form producer for a whole script", maxVoxChars, n)}
	}
	style, err := voxStyle(body, v)
	if err != nil {
		return nil, err
	}
	if style != "" && strings.HasPrefix(strings.TrimSpace(input), "(") {
		return nil, &requestError{`text starts with "(" which voxcpm2 reads as a style tag; with instructions set, rephrase the start`}
	}
	ultimate, err := voxCloneMode(body, v, style, input)
	if err != nil {
		return nil, err
	}
	cfg, steps, err := voxSampling(body)
	if err != nil {
		return nil, err
	}
	seed, err := voxSeed(body)
	if err != nil {
		return nil, err
	}
	text := input
	if style != "" {
		text = "(" + style + ")" + input
	}
	out := map[string]any{
		fieldModel: config.TTSModelVoxCPM2, fieldInput: text, "response_format": "wav",
		fieldSeed: seed, "guidance_scale": cfg, "num_inference_steps": steps,
		"options": map[string]any{
			"retry_badcase": true, "retry_badcase_max_times": voxRetryTimes,
			"retry_badcase_ratio_threshold": voxRetryRatio,
		},
	}
	if v != nil {
		out["voice_ref"] = map[string]any{"type": "path", "path": wavPath}
		if ultimate {
			out["prompt_audio"] = wavPath
			out["reference_text"] = v.RefText
		}
	}
	return &voxReq{body: out, budgetSec: lengthBudget(input), seed: seed}, nil
}

// voxSeed is the request's seed, validated, else a fresh random one.
func voxSeed(body map[string]any) (int64, error) {
	raw, ok := body[fieldSeed]
	if !ok {
		return randomSeed(), nil
	}
	f, ok := number(raw)
	if !ok || f < 0 || f > maxVoxSeed || f != math.Trunc(f) {
		return 0, &requestError{fmt.Sprintf("seed must be an integer in 0..%d", uint32(maxVoxSeed))}
	}
	if s := seedOf(body); s != nil {
		return *s, nil
	}
	return int64(f), nil
}

// voxStyle is the request's instructions, else the voice's default style,
// made safe to sit inside the engine's leading "(...)" tag.
func voxStyle(body map[string]any, v *voices.Voice) (string, error) {
	style, _ := body[fieldInstruct].(string)
	if strings.TrimSpace(style) == "" && v != nil {
		style = v.Style
	}
	style = sanitizeStyle(style)
	if utf8.RuneCountInString(style) > maxStyleChars {
		return "", &requestError{fmt.Sprintf("instructions are longer than %d characters", maxStyleChars)}
	}
	return style, nil
}

// sanitizeStyle makes s a single-line phrase that cannot close or reopen the
// engine's style tag: the engine reads the first "(...)" of the text as the
// tag, so a ")" in the style would end it early and the rest would be spoken,
// and "(" would start a second one. Parentheses (ASCII and full-width) are
// dropped; newlines, tabs and every other control character become a space;
// runs of white space collapse.
func sanitizeStyle(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '(' || r == ')' || r == '\uFF08' || r == '\uFF09':
		case unicode.IsControl(r):
			b.WriteRune(' ')
		default:
			b.WriteRune(r)
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// voxCloneMode decides ultimate (reference + its transcript as a continuation
// prompt: most faithful, keeps the reference's own delivery and language) vs
// reference cloning (timbre; a style can steer delivery). auto picks ultimate
// only when the voice has a transcript, no style is set and the text is in
// the transcript's script — a Russian clip speaking English would otherwise
// carry its accent (council M7; voices.SameScript).
func voxCloneMode(body map[string]any, v *voices.Voice, style, input string) (ultimate bool, err error) {
	mode, _ := body["clone_mode"].(string)
	switch mode {
	case "", cloneAuto:
		return v != nil && v.RefText != "" && style == "" && voices.SameScript(v.RefText, input), nil
	case cloneReference:
		if v == nil {
			return false, &requestError{"clone_mode reference needs a voice"}
		}
		return false, nil
	case cloneUltimate:
		switch {
		case v == nil:
			return false, &requestError{"clone_mode ultimate needs a voice"}
		case v.RefText == "":
			return false, &requestError{fmt.Sprintf("clone_mode ultimate needs a voice with ref_text; %q has none", v.Name)}
		case style != "":
			return false, &requestError{"clone_mode ultimate continues the reference's own delivery and ignores a style: drop instructions or use clone_mode reference"}
		}
		return true, nil
	}
	return false, &requestError{fmt.Sprintf("clone_mode %q: want auto|reference|ultimate", mode)}
}

// voxSampling reads cfg_value and inference_timesteps with their defaults.
func voxSampling(body map[string]any) (cfg float64, steps int, err error) {
	cfg, steps = defaultCfgValue, defaultTimesteps
	if raw, ok := body["cfg_value"]; ok {
		f, ok := number(raw)
		if !ok || f <= 0 || f > maxCfgValue {
			return 0, 0, &requestError{fmt.Sprintf("cfg_value must be in (0, %.0f]; %.1f is the default", maxCfgValue, defaultCfgValue)}
		}
		cfg = f
	}
	if raw, ok := body["inference_timesteps"]; ok {
		f, ok := number(raw)
		if !ok || f < 1 || f > maxTimesteps || f != math.Trunc(f) {
			return 0, 0, &requestError{fmt.Sprintf("inference_timesteps must be an integer in 1..%d; %d is the default", maxTimesteps, defaultTimesteps)}
		}
		steps = int(f)
	}
	return cfg, steps, nil
}

// randomSeed draws a seed when the caller sets none: audio.cpp's own default
// is a fixed 1234, which would make every unseeded take identical.
func randomSeed() int64 {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return time.Now().UnixNano() & maxVoxSeed
	}
	return int64(binary.LittleEndian.Uint32(b[:]))
}

// resolveVoxVoice loads the request's voice for the voxcpm2 adapter and
// re-checks its stored recording against the encoder window: a voice added
// before the limit, hand-placed, or routed here by a global default was never
// checked by the add path, and the engine answers HTTP 500 past the window.
func (d *Daemon) resolveVoxVoice(body map[string]any) (v *voices.Voice, wavPath string, err error) {
	name, _ := body[fieldVoice].(string)
	if name == "" {
		return nil, "", nil
	}
	got, err := d.Store.Get(name)
	if err != nil {
		return nil, "", &requestError{fmt.Sprintf("voice %q: %v", name, err)}
	}
	wavPath = d.Store.WAVPath(name)
	secs, err := voices.WAVSeconds(wavPath)
	if err != nil {
		return nil, "", fmt.Errorf("voice %s: cannot read its recording: %w", name, err)
	}
	if err := checkVoxReference(secs); err != nil {
		return nil, "", err
	}
	return got, wavPath, nil
}

// synthesizeVoxCPM2 renders a prepared body on the voxcpm2 child. The engine
// bounds and retries runaways itself; a take longer than the plausibility
// budget is returned with a warning. The availability check comes first: the
// supervisor exists on every unified-memory Mac, with or without the model.
func (d *Daemon) synthesizeVoxCPM2(ctx context.Context, body map[string]any) (*synthOut, error) {
	if why := d.voxUnavailable(); why != "" {
		return nil, &unavailableError{why}
	}
	v, wavPath, err := d.resolveVoxVoice(body)
	if err != nil {
		return nil, err
	}
	req, err := buildVoxCPM2(body, v, wavPath)
	if err != nil {
		return nil, err
	}
	start := time.Now()
	wav, err := d.speechOn(ctx, d.VoxSup, req.body)
	if err != nil {
		return nil, err
	}
	dur := wavDuration(wav)
	seed := req.seed
	d.log.Info("voxcpm2 render", slog.Int64("seed", seed), slog.Bool("voice", v != nil),
		slog.Float64("audio_s", dur), slog.Float64("elapsed_s", time.Since(start).Seconds()))
	out := &synthOut{WAV: wav, Model: config.TTSModelVoxCPM2, Seed: &seed}
	if dur > req.budgetSec {
		d.log.Warn("voxcpm2 runaway suspected: the take is longer than its text plausibly needs",
			slog.Float64("budget_s", req.budgetSec), slog.Float64("audio_s", dur), slog.Int64("seed", seed))
		out.Warning = fmt.Sprintf("the take is %.1f s, longer than its text plausibly needs (%.1f s): it may contain babble; re-render with another seed", dur, req.budgetSec)
	}
	return out, nil
}
