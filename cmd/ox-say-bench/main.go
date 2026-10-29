// Command ox-say-bench measures ox-say's engines on this Mac and prints a
// Markdown report: Qwen3-TTS start time, first-audio latency and real-time
// factor (default and cloned voice, English and Russian); Parakeet
// whole-clip latency by clip length on the GPU (Metal) and on the CPU
// (-ng) — warm, at server start and after an idle pause; streaming-session
// finish latency; the 6-minute CLI run; STT latency while TTS synthesizes;
// and each engine's peak RSS. It spawns the real binaries through
// engine.Supervisor — the daemon's own spawn, health and kill path — on
// free loopback ports under a scratch directory. A developer tool: it is
// not packaged.
//
//	go run ./cmd/ox-say-bench -engine build/engine/out -models <dir> -out report.md
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
)

const (
	defaultRuns = 3
	defaultIdle = 120 * time.Second
	dirPerm     = 0o755
	filePerm    = 0o644
	defaultTalk = "qwen-talker-0.6b-base-Q8_0.gguf"
)

type options struct {
	engineDir string
	modelsDir string
	ttsModels []string // talker GGUFs, measured in order
	work      string
	out       string
	runs      int
	idle      time.Duration
	keep      bool
}

func parseFlags() (options, error) {
	var o options
	var tts string
	flag.StringVar(&o.engineDir, "engine", "build/engine/out", "directory holding tts-server and ox-stt")
	flag.StringVar(&o.modelsDir, "models", "", "models directory in the scripts/fetch-models.sh layout (required)")
	flag.StringVar(&tts, "tts-models", defaultTalk, "comma-separated talker GGUFs, absolute or relative to -models")
	flag.StringVar(&o.work, "work", "", "scratch directory for clips, logs and pidfiles (default: a new temp dir)")
	flag.StringVar(&o.out, "out", "", "also write the report to this file")
	flag.IntVar(&o.runs, "runs", defaultRuns, "warm runs per measurement; the median is reported")
	flag.DurationVar(&o.idle, "idle", defaultIdle, "pause before the after-idle STT call")
	flag.BoolVar(&o.keep, "keep", false, "keep the scratch directory after a successful run")
	flag.Parse()
	if o.modelsDir == "" {
		return o, errors.New("-models is required")
	}
	if o.runs < 1 {
		return o, errors.New("-runs must be at least 1")
	}
	for _, m := range strings.Split(tts, ",") {
		if m = strings.TrimSpace(m); m == "" {
			continue
		}
		if !filepath.IsAbs(m) {
			m = filepath.Join(o.modelsDir, m)
		}
		o.ttsModels = append(o.ttsModels, m)
	}
	return o, nil
}

func main() {
	o, err := parseFlags()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ox-say-bench:", err)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err = runLocked(ctx, o, bench)
	stop()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ox-say-bench:", err)
		os.Exit(1)
	}
}

// runLocked runs the measurements while holding the bench lock; run is not
// called when another bench holds it.
func runLocked(ctx context.Context, o options, run func(context.Context, options) error) error {
	unlock, err := lockRun()
	if err != nil {
		return err
	}
	defer unlock()
	return run(ctx, o)
}

// newReport starts the report: the run count its footnote names and the host
// lines, with the engine pins read from the stamp next to o.engineDir's binaries.
func newReport(ctx context.Context, o options) *report {
	r := &report{runs: o.runs}
	r.host(ctx, o.engineDir)
	return r
}

// bench runs every measurement. A failing TTS model or STT device is
// recorded as a note and the rest still runs: a 1.7B load failure is a
// result, not a reason to lose the STT numbers.
func bench(ctx context.Context, o options) error {
	temp := o.work == ""
	if temp {
		dir, err := os.MkdirTemp("", "ox-say-bench-")
		if err != nil {
			return err
		}
		o.work = dir
	}
	// stt.Transcribe (the daemon-path row) refuses a relative audio path.
	work, err := filepath.Abs(o.work)
	if err != nil {
		return err
	}
	o.work = work
	fmt.Fprintln(os.Stderr, "ox-say-bench: scratch directory", o.work)
	for _, sub := range []string{"clips", "logs"} {
		if err := os.MkdirAll(filepath.Join(o.work, sub), dirPerm); err != nil {
			return err
		}
	}
	cl, err := makeClips(ctx, filepath.Join(o.work, "clips"))
	if err != nil {
		return err
	}
	r := newReport(ctx, o)
	warmShaders(ctx, o, r)
	for _, m := range o.ttsModels {
		if err := measureTTS(ctx, o, cl, m, r); err != nil {
			r.fail("TTS %s: %v", filepath.Base(m), err)
		}
	}
	for _, dev := range devices {
		if err := measureSTT(ctx, o, cl, dev, r); err != nil {
			r.fail("STT %s: %v", dev.name, err)
		}
	}
	if err := measureContention(ctx, o, cl, r); err != nil {
		r.fail("STT under TTS load: %v", err)
	}
	if err := ctx.Err(); err != nil {
		r.fail("interrupted: %v", err)
	}
	text := r.markdown()
	fmt.Print(text)
	if o.out != "" {
		if err := os.WriteFile(o.out, []byte(text), filePerm); err != nil {
			return err
		}
	}
	if len(r.partial) > 0 {
		fmt.Fprintln(os.Stderr, "ox-say-bench: scratch directory kept:", o.work)
		return fmt.Errorf("partial run: %d measurement(s) failed or were interrupted", len(r.partial))
	}
	// Only a directory the tool created itself is removed.
	if temp && !o.keep {
		if err := os.RemoveAll(o.work); err != nil {
			fmt.Fprintln(os.Stderr, "ox-say-bench: remove scratch directory:", err)
		}
	}
	return nil
}

// warmShaders spawns each engine once and discards it. The first start of a
// freshly built binary compiles its Metal library, and that one-time cost
// would otherwise land in whichever row ran first. It is reported as a note.
func warmShaders(ctx context.Context, o options, r *report) {
	warm := func(label, name string, cfg engine.Config) {
		c, err := startChild(ctx, o.work, name, cfg)
		if err != nil {
			r.fail("%s first start failed: %v", label, err)
			return
		}
		r.note("%s first start (includes any Metal library compile; macOS caches compiled libraries, so later starts are fast; excluded from the tables): %.2f s", label, c.start.Seconds())
		c.stop()
	}
	if len(o.ttsModels) > 0 {
		warm("tts-server", "tts-warm", ttsConfig(o, o.ttsModels[0]))
	}
	warm("ox-stt (Metal)", "stt-warm", sttConfig(o, devices[0]))
}
