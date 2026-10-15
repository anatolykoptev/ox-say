package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Speech request fields the router and the adapters read.
const (
	fieldInput    = "input"
	fieldVoice    = "voice"
	fieldModel    = "model"
	fieldSeed     = "seed"
	fieldInstruct = "instructions"
)

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

// engineError is a non-2xx answer from an engine child; its status is kept
// (audio.cpp's 400 capacity / 503 server_busy must not become 502).
type engineError struct {
	status int
	msg    string
}

func (e *engineError) Error() string { return e.msg }

// errEngineStart marks a child that failed to become ready (HTTP 503).
var errEngineStart = errors.New("engine failed to start")

// synthStatus maps a synthesis/voice error to its HTTP status.
func synthStatus(err error) int {
	var re *requestError
	var ue *unavailableError
	var ie *voices.InputError
	var ee *engineError
	switch {
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
	m, _ := body[fieldModel].(string)
	switch name := strings.TrimSpace(m); name {
	case config.TTSModelVoxCPM2, config.TTSModelQwen:
		model = name
	default:
		model = d.Cfg.TTSModel
		if vname, _ := body[fieldVoice].(string); vname != "" {
			if v, gerr := d.Store.Get(vname); gerr == nil && v.Engine != "" {
				model = v.Engine
			}
		}
		if model == config.TTSModelVoxCPM2 {
			if why := d.voxUnavailable(); why != "" {
				model, warning = config.TTSModelQwen, "spoken by qwen3-tts: "+why
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

// voxUnavailable is the plain-words reason the voxcpm2 engine cannot serve
// this request, or "" when it can. Every route to the child checks it before
// touching the supervisor, which exists whenever the memory is unified — even
// with no model on disk.
func (d *Daemon) voxUnavailable() string {
	if why := d.Cfg.VoxCPM2Unavailable(); why != "" {
		return why
	}
	if d.VoxSup == nil {
		return "The studio voice engine is not running on this host."
	}
	return ""
}

// synthesize renders a prepared body on model. It applies no defaults.
func (d *Daemon) synthesize(ctx context.Context, body map[string]any, model string) (*synthOut, error) {
	body["response_format"] = "wav"
	if model == config.TTSModelVoxCPM2 {
		return d.synthesizeVoxCPM2(ctx, body)
	}
	wav, err := d.synthesizeQwen(ctx, body)
	if err != nil {
		return nil, err
	}
	return &synthOut{WAV: wav, Model: config.TTSModelQwen, Seed: seedOf(body)}, nil
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
