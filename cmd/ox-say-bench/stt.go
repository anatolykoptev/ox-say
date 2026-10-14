package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/daemon"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

const (
	parakeetFile  = "ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
	vadFile       = "ggml-silero-v5.1.2.bin"
	probeClip     = 30 // s: the first-call and under-load clip
	idleClip      = 60 // s: the after-idle and daemon-path clip (the streaming plan's 60 s dictation)
	gpuAuto       = "auto"
	gpuOff        = "off"
	sessionChunk  = 500 * time.Millisecond
	f32Bytes      = 4
	sttRespMax    = 8 << 20
	jsonType      = "application/json"
	octetType     = "application/octet-stream"
	wavType       = "audio/wav"
	errSnippetMax = 300
)

type device struct {
	name string
	cpu  bool // -ng
}

var devices = []device{{name: "Metal", cpu: false}, {name: "CPU (-ng)", cpu: true}}

// sttGPU is the OX_SAY_STT_GPU value that puts the device under test on
// Apple Silicon: auto keeps the server on Metal, off adds -ng.
func (dev device) sttGPU() string {
	if dev.cpu {
		return gpuOff
	}
	return gpuAuto
}

// sttConfig spawns the resident server with the daemon's own argv
// (daemon.STTServeArgs) for an Apple Silicon install, so the bench cannot
// drift from what the daemon runs.
func sttConfig(o options, dev device) engine.Config {
	cfg := &config.Config{
		STTModel:    filepath.Join(o.modelsDir, parakeetFile),
		STTVADModel: filepath.Join(o.modelsDir, vadFile),
		STTGPU:      dev.sttGPU(),
		GPUMemory:   config.GPUMemoryUnified,
	}
	return engine.Config{
		Bin:  filepath.Join(o.engineDir, "ox-stt"),
		Args: func(port int) []string { return daemon.STTServeArgs(cfg, port) },
	}
}

func measureSTT(ctx context.Context, o options, cl *clips, dev device, r *report) error {
	c, err := startChild(ctx, o.work, "stt", sttConfig(o, dev))
	if err != nil {
		return err
	}
	defer func() {
		rss, fp := c.stop()
		r.sttCell("Peak RSS (ps), resident server", dev.name, fmt.Sprintf("%.0f MB", rss))
		r.sttCell("Peak physical footprint (vmmap), resident server", dev.name, fp)
	}()
	r.sttCell("Server start (spawn to ready)", dev.name, fmt.Sprintf("%.2f s", c.start.Seconds()))
	if err := sweep(ctx, o, cl, c.base, dev, r); err != nil {
		return err
	}
	if err := daemonPath(ctx, o, cl, c.base, dev, r); err != nil {
		return err
	}
	if err := afterIdle(ctx, o, cl, c.base, dev, r); err != nil {
		return err
	}
	if err := sessionFinish(ctx, o, cl, c.base, dev, r); err != nil {
		return err
	}
	return cliLong(ctx, o, cl, dev, r)
}

// sweep times the first call after start, then the warm whole-clip
// latency of every sweep length (one discarded call per length).
func sweep(ctx context.Context, o options, cl *clips, base string, dev device, r *report) error {
	probe, err := cl.wav(ctx, probeClip)
	if err != nil {
		return err
	}
	d, err := transcribe(ctx, base, probe)
	if err != nil {
		return err
	}
	r.sttCell(fmt.Sprintf("First call after start, %d s clip", probeClip), dev.name, speed(d.Seconds(), probeClip))
	for _, n := range sweepLengths {
		wav, err := cl.wav(ctx, n)
		if err != nil {
			return err
		}
		if _, err := transcribe(ctx, base, wav); err != nil {
			return err
		}
		var walls []float64
		for range o.runs {
			d, err := transcribe(ctx, base, wav)
			if err != nil {
				return err
			}
			walls = append(walls, d.Seconds())
		}
		r.sttCell(fmt.Sprintf("Whole clip %d s, warm", n), dev.name, speed(median(walls), n))
	}
	return nil
}

// daemonPath times the 60 s clip through stt.Transcribe — the daemon's own
// path: ffmpeg conversion to a 16 kHz WAV, then the resident server — so
// the conversion cost a dictation pays is in the number. A server failure
// fails the row instead of falling back to the CLI unseen.
func daemonPath(ctx context.Context, o options, cl *clips, base string, dev device, r *report) error {
	wav, err := cl.wav(ctx, idleClip)
	if err != nil {
		return err
	}
	var serverErr error
	opts := stt.Options{
		Bin:           filepath.Join(o.engineDir, "ox-stt"),
		Model:         filepath.Join(o.modelsDir, parakeetFile),
		GPU:           dev.sttGPU(),
		Server:        func(context.Context) (string, func(), error) { return base, func() {}, nil },
		OnServerError: func(err error) { serverErr = err },
	}
	var walls []float64
	for range o.runs {
		t0 := time.Now()
		res, err := stt.Transcribe(ctx, wav, opts)
		if err != nil {
			return err
		}
		if serverErr != nil {
			return fmt.Errorf("daemon path: resident server failed: %w", serverErr)
		}
		if strings.TrimSpace(res.Text) == "" {
			return errors.New("daemon path: no text")
		}
		walls = append(walls, time.Since(t0).Seconds())
	}
	r.sttCell(fmt.Sprintf("Daemon path (ffmpeg + server), %d s clip, warm", idleClip), dev.name, speed(median(walls), idleClip))
	return nil
}

// afterIdle waits o.idle, then times one 60 s call. On a Mac under memory
// pressure the model may have been compressed or paged out meanwhile; on a
// Mac with free memory (48 GB here) it usually stays resident, which the
// row label cannot tell — read it with the host's memory in mind.
func afterIdle(ctx context.Context, o options, cl *clips, base string, dev device, r *report) error {
	wav, err := cl.wav(ctx, idleClip)
	if err != nil {
		return err
	}
	select {
	case <-time.After(o.idle):
	case <-ctx.Done():
		return ctx.Err()
	}
	d, err := transcribe(ctx, base, wav)
	if err != nil {
		return err
	}
	r.sttCell(fmt.Sprintf("First call after %s idle, %d s clip", o.idle, idleClip), dev.name, speed(d.Seconds(), idleClip))
	return nil
}

// sessionFinish streams a clip through a dictation session in real time —
// 0.5 s chunks, paced like a microphone — and times /finish: the
// release-to-text latency of a dictation that long.
func sessionFinish(ctx context.Context, o options, cl *clips, base string, dev device, r *report) error {
	raw, err := cl.f32(ctx, sessionClip)
	if err != nil {
		return err
	}
	pcm, err := os.ReadFile(raw)
	if err != nil {
		return err
	}
	var walls []float64
	for range o.runs {
		d, err := oneSession(ctx, base, pcm)
		if err != nil {
			return err
		}
		walls = append(walls, d.Seconds())
	}
	r.sttCell(fmt.Sprintf("Session /finish after %d s streamed in real time", sessionClip), dev.name,
		fmt.Sprintf("%.2f s", median(walls)))
	return nil
}

func oneSession(ctx context.Context, base string, pcm []byte) (time.Duration, error) {
	out, err := post(ctx, base+"/sessions", jsonType, []byte("{}"))
	if err != nil {
		return 0, err
	}
	var s struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(out, &s); err != nil || s.ID == "" {
		return 0, fmt.Errorf("session create: %.*s", errSnippetMax, out)
	}
	chunk := int(sessionChunk.Seconds()*sttSampleRate) * f32Bytes
	for off := 0; off < len(pcm); off += chunk {
		end := min(off+chunk, len(pcm))
		if _, err := post(ctx, base+"/sessions/"+s.ID+"/audio", octetType, pcm[off:end]); err != nil {
			return 0, err
		}
		if end < len(pcm) {
			select {
			case <-time.After(sessionChunk):
			case <-ctx.Done():
				return 0, ctx.Err()
			}
		}
	}
	t0 := time.Now()
	out, err = post(ctx, base+"/sessions/"+s.ID+"/finish", jsonType, []byte("{}"))
	d := time.Since(t0)
	if err != nil {
		return 0, err
	}
	var res struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(out, &res); err != nil || strings.TrimSpace(res.Text) == "" {
		return 0, fmt.Errorf("session finish returned no text: %.*s", errSnippetMax, out)
	}
	return d, nil
}

// cliLong runs the per-call ox-stt CLI on the 6-minute clip — the README's
// Intel figure ("6 minutes of audio in about 18 s"), model load included.
func cliLong(ctx context.Context, o options, cl *clips, dev device, r *report) error {
	wav, err := cl.wav(ctx, longClip)
	if err != nil {
		return err
	}
	args := []string{"-m", filepath.Join(o.modelsDir, parakeetFile), "-f", wav, "--engine", "parakeet"}
	if dev.cpu {
		args = append(args, "-ng")
	}
	cmd := exec.CommandContext(ctx, filepath.Join(o.engineDir, "ox-stt"), args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	t0 := time.Now()
	out, err := cmd.Output()
	d := time.Since(t0)
	if err != nil {
		return fmt.Errorf("ox-stt CLI: %w: %.*s", err, errSnippetMax, stderr.String())
	}
	var res stt.Result
	if err := json.Unmarshal(out, &res); err != nil || strings.TrimSpace(res.Text) == "" {
		return errors.New("ox-stt CLI returned no text")
	}
	r.sttCell(fmt.Sprintf("CLI, %d s clip, model load included", longClip), dev.name, speed(d.Seconds(), longClip))
	return nil
}

// measureContention times a warm whole-clip decode on the Metal server
// while tts-server synthesizes back to back on the same GPU — the Apple
// Silicon default runs both side by side.
func measureContention(ctx context.Context, o options, cl *clips, r *report) error {
	if len(o.ttsModels) == 0 {
		return nil
	}
	tts, err := startChild(ctx, o.work, "tts-load", ttsConfig(o, o.ttsModels[0]))
	if err != nil {
		return err
	}
	defer tts.stop()
	sc, err := startChild(ctx, o.work, "stt-load", sttConfig(o, devices[0]))
	if err != nil {
		return err
	}
	defer sc.stop()
	wav, err := cl.wav(ctx, probeClip)
	if err != nil {
		return err
	}
	if _, err := transcribe(ctx, sc.base, wav); err != nil {
		return err
	}
	lctx, cancel := context.WithCancel(ctx)
	loadDone := make(chan error, 1)
	started := make(chan struct{})
	go func() { loadDone <- ttsLoad(lctx, tts.base, started) }()
	// time only decodes that overlap a running synthesis
	select {
	case <-started:
	case err := <-loadDone:
		cancel()
		return fmt.Errorf("tts load: %w", err)
	}
	var walls []float64
	var terr error
	for range o.runs {
		d, err := transcribe(ctx, sc.base, wav)
		if err != nil {
			terr = err
			break
		}
		walls = append(walls, d.Seconds())
	}
	cancel()
	if lerr := <-loadDone; lerr != nil && !errors.Is(lerr, context.Canceled) {
		return lerr
	}
	if terr != nil {
		return terr
	}
	r.sttCell(fmt.Sprintf("Whole clip %d s while tts-server synthesizes", probeClip), devices[0].name,
		speed(median(walls), probeClip))
	return nil
}

// ttsLoad synthesizes back to back until ctx ends. It closes started once
// the first synthesis has finished, so the load is warm and continuous
// before any decode is timed against it.
func ttsLoad(ctx context.Context, base string, started chan<- struct{}) error {
	ec := engine.NewClient()
	once := false
	for ctx.Err() == nil {
		if _, err := synth(ctx, ec, base, ttsCases[0]); err != nil {
			return err
		}
		if !once {
			close(started)
			once = true
		}
	}
	return ctx.Err()
}

// transcribe POSTs a WAV to the server's /transcribe, as the daemon does,
// checks that text came back, and returns the wall time.
func transcribe(ctx context.Context, base, wav string) (time.Duration, error) {
	body, err := os.ReadFile(wav)
	if err != nil {
		return 0, err
	}
	t0 := time.Now()
	out, err := post(ctx, base+"/transcribe", wavType, body)
	d := time.Since(t0)
	if err != nil {
		return 0, err
	}
	var res stt.Result
	if err := json.Unmarshal(out, &res); err != nil || strings.TrimSpace(res.Text) == "" {
		return 0, fmt.Errorf("transcribe returned no text: %.*s", errSnippetMax, out)
	}
	return d, nil
}

// post sends one request and returns the body of a 200 response.
func post(ctx context.Context, url, contentType string, body []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", contentType)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(io.LimitReader(resp.Body, sttRespMax))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s: %.*s", url, resp.Status, errSnippetMax, out)
	}
	return out, nil
}

func speed(wallS float64, audioS int) string {
	return fmt.Sprintf("%.2f s (%.0f× RT)", wallS, float64(audioS)/wallS)
}
