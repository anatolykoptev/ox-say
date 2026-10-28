package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// exportsSubdir is the fallback output root under the daemon's home when the
// config names none (a Config literal in a test).
const exportsSubdir = "exports"

// portFuncs implements producePorts with closures; (*Daemon).producePorts
// fills it, so no type in the producer holds a *Daemon.
type portFuncs struct {
	render       func(context.Context, renderParams) (*synthOut, error)
	hear         func(context.Context, string) ([]voices.Word, error)
	voice        func(string) (voiceFacts, error)
	defaultVoice func(string) string
	unavailable  func() string
	engineID     func() (string, error)
	normalize    func(context.Context, string, string, float64, float64) (bool, error)
	quiet        func(context.Context, func()) error
	power        func(context.Context) (bool, bool)
	background   func(bool)
	home         func() string
	outputRoot   func() string
}

func (f *portFuncs) Render(ctx context.Context, p renderParams) (*synthOut, error) {
	return f.render(ctx, p)
}
func (f *portFuncs) Hear(ctx context.Context, path string) ([]voices.Word, error) {
	return f.hear(ctx, path)
}
func (f *portFuncs) Voice(name string) (voiceFacts, error) { return f.voice(name) }
func (f *portFuncs) DefaultVoice(lang string) string       { return f.defaultVoice(lang) }
func (f *portFuncs) Unavailable() string                   { return f.unavailable() }
func (f *portFuncs) EngineID() (string, error)             { return f.engineID() }
func (f *portFuncs) Normalize(ctx context.Context, in, out string, lufs, dur float64) (bool, error) {
	return f.normalize(ctx, in, out, lufs, dur)
}
func (f *portFuncs) Quiet(ctx context.Context, onWait func()) error { return f.quiet(ctx, onWait) }
func (f *portFuncs) Power(ctx context.Context) (bool, bool)         { return f.power(ctx) }
func (f *portFuncs) Background(on bool)                             { f.background(on) }
func (f *portFuncs) Home() string                                   { return f.home() }
func (f *portFuncs) OutputRoot() string                             { return f.outputRoot() }

// strictNormalize is the Normalize port: the STRICT loudnormFileReport
// under a timeout proportional to the duration. It must never be the soft
// normalizeLoudness, which returns the unnormalised audio on a failure - an
// unnormalised file may not pass for a published one (#154.6, D16).
func strictNormalize(ctx context.Context, in, out string, lufs, dur float64) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, loudnormFileTimeout(dur))
	defer cancel()
	return loudnormFileReport(ctx, in, out, lufs)
}

// engineIdentity hashes audiocpp_server and names the model file and size.
func engineIdentity(bin, model string) (string, error) {
	sha, err := fileSHA(bin)
	if err != nil {
		return "", fmt.Errorf("the studio voice engine cannot be read: %w", err)
	}
	st, err := os.Stat(model)
	if err != nil {
		return "", fmt.Errorf("the studio voice model cannot be read: %w", err)
	}
	return fmt.Sprintf("%s:%s:%d", sha[:24], filepath.Base(model), st.Size()), nil
}

// producePorts adapts the daemon. EngineID is hashed once per daemon
// process once it has succeeded (an error is not cached): replacing audiocpp_server or the model on disk without
// restarting the daemon keeps the old identity, so cached takes rendered
// by the old engine are reused until the next restart. Every supported
// upgrade path (the installer) restarts the LaunchAgent; a hand swap must
// be followed by a daemon restart.
func (d *Daemon) producePorts() producePorts {
	var idMu sync.Mutex
	var engineID string // cached on success only: a failure is retried by the next job
	var mu sync.Mutex
	bg := false
	applyQoS := func() {
		if d.VoxSup == nil {
			return
		}
		mu.Lock()
		on := bg
		mu.Unlock()
		if pid := d.VoxSup.Status().PID; pid > 0 {
			if err := setBackground(pid, on); err != nil {
				d.log.Warn("produce: cannot set the engine's priority", "error", err)
			}
		}
	}
	return &portFuncs{
		// Render sends the typed request through the speech router's own map
		// (every VoxCPM2 rule stays in voxcpm2.go) and keeps the child at the
		// wanted QoS.
		render: func(ctx context.Context, p renderParams) (*synthOut, error) {
			applyQoS()
			out, err := d.render(ctx, p.body())
			applyQoS() // the child may have (re)started for this request
			return out, err
		},
		// hear is the daemon's own STT through Transcribe, never an HTTP route: no stamp.
		hear: d.voiceWords,
		// voice reads the voice live and re-checks its clip (#141.2).
		voice: func(name string) (voiceFacts, error) {
			v, err := d.Store.Get(name)
			if err != nil {
				return voiceFacts{}, &requestError{fmt.Sprintf("voice %q: %v", name, err)}
			}
			if err := d.checkStoredVoxReference(name); err != nil {
				return voiceFacts{}, err
			}
			sha, err := fileSHA(d.Store.WAVPath(name))
			if err != nil {
				d.log.Warn("produce: cannot read a voice recording", "voice", name, "error", err)
				return voiceFacts{}, &requestError{fmt.Sprintf("voice %q: its recording cannot be read; add the voice again", name)}
			}
			return voiceFacts{Name: v.Name, RefText: v.RefText, Style: v.Style, SHA: sha}, nil
		},
		defaultVoice: d.configuredVoice,
		unavailable:  d.voxUnavailable,
		engineID: func() (string, error) {
			idMu.Lock()
			defer idMu.Unlock()
			if engineID != "" {
				return engineID, nil
			}
			id, err := engineIdentity(d.Cfg.VoxCPM2Bin, d.Cfg.VoxCPM2Model)
			if err == nil {
				engineID = id
			}
			return id, err
		},
		normalize: strictNormalize,
		quiet:     d.waitQuiet,
		power:     powerState,
		background: func(on bool) {
			mu.Lock()
			bg = on
			mu.Unlock()
			applyQoS()
		},
		home: func() string { return d.Cfg.Home },
		// outputRoot is the QF5 default (config.DefaultProduceOutDir), or the
		// operator's OX_SAY_PRODUCE_OUT_DIR.
		outputRoot: func() string {
			if d.Cfg.ProduceOutDir != "" {
				return d.Cfg.ProduceOutDir
			}
			return filepath.Join(d.Cfg.Home, produceDir, exportsSubdir)
		},
	}
}

// StartProducer enables the producer (called from cmdServe after the voice
// repair starts); StopProducer stops it within stopBound (idempotent).
func (d *Daemon) StartProducer() { d.prod.start() }
func (d *Daemon) StopProducer()  { d.prod.shutdown() }
