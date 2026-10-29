package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
)

const (
	pcmBytesPerSec = 24000 * 2 // tts-server pcm: s16le, 24 kHz, mono
	benchSeed      = 42
	cloneName      = "bench-ru"
	codecFile      = "qwen-tokenizer-12hz-F32.gguf"
	readChunk      = 4096
	errBodyMax     = 4096
	msPerSec       = 1000
	langEnglish    = "English"
	langRussian    = "Russian"
)

const (
	enSentence = "The quick brown fox jumps over the lazy dog, and then it runs back home before the evening rain begins."
	ruSentence = "Съешь же ещё этих мягких французских булок, да выпей чаю, пока не начался вечерний дождь."
)

type ttsCase struct{ lang, voice, text string }

var ttsCases = []ttsCase{
	{langEnglish, "", enSentence},
	{langEnglish, cloneName, enSentence},
	{langRussian, "", ruSentence},
	{langRussian, cloneName, ruSentence},
}

type ttsRow struct {
	model, voice, lang string
	start              time.Duration
	firstAudioMS, rtf  float64 // medians
	rssMB              float64
	footprint          string // vmmap peak physical footprint
}

type ttsRun struct {
	ttfb, total time.Duration
	audioS      float64
}

// ttsConfig is the daemon's tts-server child: same argv builder (the
// supervisor's default), same max batch as a default install.
func ttsConfig(o options, model string) engine.Config {
	return engine.Config{
		Bin:      filepath.Join(o.engineDir, "tts-server"),
		Model:    model,
		Codec:    filepath.Join(o.modelsDir, codecFile),
		MaxBatch: config.DefaultMaxBatch,
	}
}

// measureTTS starts tts-server on one talker model, registers the cloned
// voice, discards the first synthesis (pipeline compile) and records the
// warm medians of every case.
func measureTTS(ctx context.Context, o options, cl *clips, model string, r *report) error {
	if _, err := os.Stat(model); err != nil {
		return err
	}
	c, err := startChild(ctx, o.work, o.pidDir, "tts", ttsConfig(o, model))
	if err != nil {
		return err
	}
	var rows []ttsRow
	defer func() {
		rss, fp := c.stop()
		for i := range rows {
			rows[i].rssMB, rows[i].footprint = rss, fp
		}
		r.tts = append(r.tts, rows...)
	}()
	ec := engine.NewClient()
	if err := ec.RegisterVoice(ctx, c.base, cloneName, cl.ref, cl.refText); err != nil {
		return err
	}
	first, err := synth(ctx, ec, c.base, ttsCases[0])
	if err != nil {
		return err
	}
	r.note("TTS %s: first synthesis after start took %.2f s (excluded from the medians)",
		filepath.Base(model), first.total.Seconds())
	for _, tc := range ttsCases {
		row, err := ttsMedians(tc, o.runs, func(tc ttsCase) (ttsRun, error) { return synth(ctx, ec, c.base, tc) })
		if err != nil {
			return err
		}
		row.model, row.start = filepath.Base(model), c.start
		rows = append(rows, row)
	}
	return nil
}

// ttsMedians is the warm medians of one case. It discards one synthesis first:
// the first cloned and the first Russian synthesis of a model pay for their own
// warm-up (voice conditioning, the language's tokenizer path) and would sit in
// the median otherwise.
func ttsMedians(tc ttsCase, runs int, run func(ttsCase) (ttsRun, error)) (ttsRow, error) {
	if _, err := run(tc); err != nil {
		return ttsRow{}, err
	}
	var first, rtf []float64
	for range runs {
		m, err := run(tc)
		if err != nil {
			return ttsRow{}, err
		}
		if m.audioS <= 0 {
			return ttsRow{}, fmt.Errorf("%s/%s: no audio", tc.lang, voiceLabel(tc.voice))
		}
		first = append(first, m.ttfb.Seconds()*msPerSec)
		rtf = append(rtf, m.total.Seconds()/m.audioS)
	}
	return ttsRow{voice: voiceLabel(tc.voice), lang: tc.lang, firstAudioMS: median(first), rtf: median(rtf)}, nil
}

func voiceLabel(v string) string {
	if v == "" {
		return "default"
	}
	return "cloned"
}

// synth streams one pcm synthesis and times its first byte and its end.
func synth(ctx context.Context, ec *engine.Client, base string, tc ttsCase) (ttsRun, error) {
	body := map[string]any{"input": tc.text, "language": tc.lang, "response_format": "pcm", "seed": benchSeed}
	if tc.voice != "" {
		body["voice"] = tc.voice
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return ttsRun{}, err
	}
	t0 := time.Now()
	resp, err := ec.Speech(ctx, base, raw)
	if err != nil {
		return ttsRun{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, errBodyMax))
		return ttsRun{}, fmt.Errorf("speech: %s: %s", resp.Status, msg)
	}
	var run ttsRun
	var n int64
	buf := make([]byte, readChunk)
	for {
		k, rerr := resp.Body.Read(buf)
		if k > 0 && run.ttfb == 0 {
			run.ttfb = time.Since(t0)
		}
		n += int64(k)
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return ttsRun{}, rerr
		}
	}
	run.total = time.Since(t0)
	run.audioS = float64(n) / pcmBytesPerSec
	return run, nil
}
