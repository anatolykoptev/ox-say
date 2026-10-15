package daemon

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
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
	if reason := d.Cfg.VoxCPM2Unavailable(); reason != "" || d.VoxSup == nil {
		if reason == "" {
			reason = "The studio voice engine is not running on this host."
		}
		return voxCPM2Status{State: stateVoxUnavailable, Reason: reason}
	}
	st := d.VoxSup.Status()
	return voxCPM2Status{
		Available: true, State: st.State, PID: st.PID, BaseURL: st.BaseURL,
		UptimeS: st.UptimeS, LastErr: st.LastErr, Starts: st.Starts, Restarts: st.Restarts,
	}
}
