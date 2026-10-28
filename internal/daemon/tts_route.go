package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vscript"
)

// Speech request fields the router and the adapters read.
const (
	fieldInput    = "input"
	fieldVoice    = "voice"
	fieldModel    = "model"
	fieldSeed     = "seed"
	fieldInstruct = "instructions"
	// fieldSeedDefaulted marks (in the daemon only, never sent) a seed that
	// came from OX_SAY_SEED and not from the caller.
	fieldSeedDefaulted = "_ox_seed_defaulted"
)

// seedFixed is the seed the request pins: present and not negative (-1 asks
// the engine to draw one, so it pins nothing).
func seedFixed(body map[string]any) (int64, bool) {
	if s := seedOf(body); s != nil && *s >= 0 {
		return *s, true
	}
	return 0, false
}

// popSeedDefaulted removes the fieldSeedDefaulted mark and reports it.
func popSeedDefaulted(body map[string]any) bool {
	_, ok := body[fieldSeedDefaulted]
	delete(body, fieldSeedDefaulted)
	return ok
}

type seedDefaultedKey struct{}

// maxEngineWAVBytes caps one rendered take read from an engine child.
const maxEngineWAVBytes = 256 << 20

// requestError is a caller mistake (HTTP 400).
type requestError struct{ msg string }

func (e *requestError) Error() string { return e.msg }

// unavailableError is an engine this host cannot run. It is the caller asking
// for something this computer cannot do, so it maps to a 4xx with the reason in
// plain words, not a server fault.
type unavailableError struct{ msg string }

func (e *unavailableError) Error() string { return e.msg }

// conflictError is a request that clashes with existing state (HTTP 409).
type conflictError struct{ msg string }

func (e *conflictError) Error() string { return e.msg }

// engineError is a non-2xx answer from an engine child; its status is kept
// (audio.cpp's 400 capacity / 503 server_busy must not become 502).
type engineError struct {
	status int
	msg    string
}

func (e *engineError) Error() string { return e.msg }

// engineTransportError is an engine child that was started but did not answer
// (a dropped connection, a body past the cap): the gateway failed, not the
// caller, so it maps to 502 like the qwen passthrough does. The detail names
// the child's address and goes to the log; the message does not.
type engineTransportError struct{ err error }

func (e *engineTransportError) Error() string {
	return "engine speech: the speech engine did not answer; try again (details are in the ox-say log)"
}
func (e *engineTransportError) Unwrap() error { return e.err }

// transientError is a failure that may pass on its own (a file that could not
// be read just now): HTTP 503, the caller may retry.
type transientError struct{ msg string }

func (e *transientError) Error() string { return e.msg }

// errEngineStart marks a child that failed to become ready (HTTP 503).
var errEngineStart = errors.New("engine failed to start")

// synthStatus maps a synthesis/voice error to its HTTP status.
func synthStatus(err error) int {
	var re *requestError
	var ue *unavailableError
	var ie *voices.InputError
	var ee *engineError
	var ce *conflictError
	var rwe *runawayError
	var te *engineTransportError
	var tre *transientError
	switch {
	case errors.As(err, &tre):
		return http.StatusServiceUnavailable
	case errors.As(err, &rwe), errors.As(err, &te):
		return http.StatusBadGateway
	case errors.As(err, &ce):
		return http.StatusConflict
	case errors.As(err, &re), errors.As(err, &ie):
		return http.StatusBadRequest
	case errors.Is(err, voices.ErrNotFound):
		return http.StatusNotFound
	case errors.As(err, &ue):
		return http.StatusUnprocessableEntity
	case errors.As(err, &ee):
		return ee.status
	case errors.Is(err, errEngineStart):
		return http.StatusServiceUnavailable
	default:
		return http.StatusInternalServerError
	}
}

// synthOut is one rendered take.
type synthOut struct {
	WAV     []byte
	Model   string
	Seed    *int64 // the seed the engine used, when known
	Warning string // non-empty: the take is suspect, or the request was degraded
}

// voxOnlyFields are VoxCPM2 knobs; on the qwen engine they are refused, not
// silently dropped — on the passthrough path as well.
var voxOnlyFields = []string{"cfg_value", "inference_timesteps", "clone_mode"}

// prepareSpeech applies the request defaults exactly once and picks the
// engine. An explicit model wins (only "voxcpm2" and "qwen3-tts" are names;
// any other string — an OpenAI "tts-1" — keeps today's meaning: the default).
// A voice's preferred engine applies next, but only where it can run: else the
// request degrades to qwen with a warning. Then OX_SAY_TTS_MODEL (qwen3-tts
// unless the owner changed it).
func (d *Daemon) prepareSpeech(body map[string]any) (model, warning string, err error) {
	d.applyLanguageDefault(body)
	d.applyVoiceDefault(body)
	d.applySeedDefault(body)
	m, _ := body[fieldModel].(string)
	name := strings.TrimSpace(m)
	switch low := strings.ToLower(name); low {
	case config.TTSModelVoxCPM2, config.TTSModelQwen:
		model = low
	default:
		if strings.HasPrefix(low, "vox") {
			// "voxcpm-2", "voxcpm": a near miss must not look like a success on
			// the wrong engine (#143.1).
			warning = fmt.Sprintf("model %q is not a model name here, so the default engine spoke; the studio voice model is %q", clipRunes(name, maxEchoedModelRunes), config.TTSModelVoxCPM2)
		}
		model = d.Cfg.TTSModel
		if vname, _ := body[fieldVoice].(string); vname != "" {
			if v, gerr := d.Store.Get(vname); gerr == nil && v.Engine != "" {
				model = v.Engine
			}
		}
		if model == config.TTSModelVoxCPM2 {
			if why := d.voxUnavailable(); why != "" {
				vname, _ := body[fieldVoice].(string)
				d.log.Warn("voice preference overridden: spoken by qwen3-tts", slog.String("voice", vname), slog.String("reason", why))
				model = config.TTSModelQwen
				warning = strings.TrimPrefix(warning+"; spoken by qwen3-tts: "+why, "; ")
				// The caller never asked for voxcpm2 (the voice or the daemon
				// default did), so its quality knobs must not turn a call that
				// can be spoken into a 400 on this host: drop them and say so.
				if dropped := dropVoxOnlyFields(body); dropped != "" {
					warning += "; ignored " + dropped + " (they apply to voxcpm2 only)"
				}
			}
		}
	}
	if model == config.TTSModelQwen {
		for _, k := range voxOnlyFields {
			if _, ok := body[k]; ok {
				return "", "", &requestError{fmt.Sprintf("%s applies to model %s only", k, config.TTSModelVoxCPM2)}
			}
		}
	}
	return model, warning, nil
}

// maxEchoedModelRunes bounds a caller's model name echoed back in a header.
const maxEchoedModelRunes = 64

// clipRunes cuts s to n runes, marking the cut, and drops control characters:
// the result goes into an HTTP header.
func clipRunes(s string, n int) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}

// dropVoxOnlyFields removes the voxcpm2 knobs from body and returns the names
// it removed, comma-separated ("" when none were set).
func dropVoxOnlyFields(body map[string]any) string {
	var dropped []string
	for _, k := range voxOnlyFields {
		if _, ok := body[k]; ok {
			delete(body, k)
			dropped = append(dropped, k)
		}
	}
	return strings.Join(dropped, ", ")
}

// voxUnavailable is the plain-words reason the voxcpm2 engine cannot serve
// this request, or "" when it can. Every route to the child checks it before
// touching the supervisor, which exists whenever the memory is unified — even
// with no model on disk.
func (d *Daemon) voxUnavailable() string {
	_, why := d.voxBlock()
	return why
}

// voxBlock is voxUnavailable with config's machine-readable code.
func (d *Daemon) voxBlock() (code, reason string) {
	if code, why := d.Cfg.VoxCPM2Block(); why != "" {
		return code, why
	}
	if d.VoxSup == nil {
		return config.VoxReasonUnsupported, "The studio voice engine is not running on this host."
	}
	return "", ""
}

// normalizeSpeakText rewrites a plain-speech request's input for the engine
// (vscript.SpokenInline: the unambiguous abbreviations are written out and
// numbers become Russian words; a leading "(…)", the engine's own style
// channel, is left for the engine to parse — it is never folded into the
// text the way produce's Spoken does for script chunks). Only a Russian
// request is rewritten — the language the daemon resolves for it (the
// language field or OX_SAY_LANG, else the input's script); anything else
// reaches the engine byte-identical. The caller's text is never the
// normalized one: responses and file names keep the input as sent.
func (d *Daemon) normalizeSpeakText(body map[string]any) {
	input, _ := body[fieldInput].(string)
	if input == "" {
		return
	}
	d.applyLanguageDefault(body)
	if langHint(body) != "ru" {
		return
	}
	body[fieldInput] = vscript.SpokenInline(input)
}

// synthesize renders a prepared body on model. It applies no defaults.
func (d *Daemon) synthesize(ctx context.Context, body map[string]any, model string) (*synthOut, error) {
	if popSeedDefaulted(body) {
		ctx = context.WithValue(ctx, seedDefaultedKey{}, true)
	}
	body["response_format"] = "wav"
	if model == config.TTSModelVoxCPM2 {
		return d.synthesizeVoxCPM2(ctx, body)
	}
	return d.synthesizeQwenSplit(ctx, body)
}

// render = prepareSpeech + synthesize on a copy of params: the speak tool,
// SynthesizeWAV and (later) voice design and the long-form producer.
func (d *Daemon) render(ctx context.Context, params map[string]any) (*synthOut, error) {
	body := maps(params)
	model, warning, err := d.prepareSpeech(body)
	if err != nil {
		return nil, err
	}
	out, err := d.synthesize(ctx, body, model)
	if err != nil {
		return nil, err
	}
	out.addWarning(warning)
	return out, nil
}

// addWarning appends w to the take's warning.
func (o *synthOut) addWarning(w string) {
	if w != "" {
		o.Warning = strings.TrimPrefix(o.Warning+"; "+w, "; ")
	}
}

// seedOf reads a request seed (int64 from Go callers, json.Number from HTTP).
func seedOf(body map[string]any) *int64 {
	switch n := body[fieldSeed].(type) {
	case int64:
		return &n
	case int:
		v := int64(n)
		return &v
	case json.Number:
		if v, err := n.Int64(); err == nil {
			return &v
		}
	case float64:
		v := int64(n)
		return &v
	}
	return nil
}

// number reads a JSON number from any shape the daemon sees.
func number(raw any) (float64, bool) {
	switch n := raw.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	}
	return 0, false
}

// setHeaders exposes a take's provenance on an HTTP response.
func (o *synthOut) setHeaders(h http.Header) {
	h.Set("X-Ox-Say-Model", o.Model)
	if o.Seed != nil {
		h.Set("X-Ox-Say-Seed", strconv.FormatInt(*o.Seed, 10))
	}
	if o.Warning != "" {
		h.Set("X-Ox-Say-Warning", o.Warning)
	}
}
