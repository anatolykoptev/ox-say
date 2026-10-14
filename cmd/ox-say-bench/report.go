package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const shortSHA = 7

// report accumulates measured rows and renders Markdown. Every number in it
// comes from a measurement of this run.
type report struct {
	hostLines []string
	tts       []ttsRow
	stt       map[string]map[string]string // row → device → cell
	sttRows   []string                     // row labels, first-seen order
	notes     []string
	partial   []string // why the run is incomplete; empty on a full run
	singles   bool     // some row is a single run, not a median
}

const singleMark = " †"

// single labels a row measured by one run rather than a median of -runs.
func (r *report) single(label string) string {
	r.singles = true
	return label + singleMark
}

// fail records a failed or interrupted measurement: a note and a reason the
// report is partial.
func (r *report) fail(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	r.notes = append(r.notes, msg)
	r.partial = append(r.partial, msg)
}

func (r *report) note(format string, args ...any) {
	r.notes = append(r.notes, fmt.Sprintf(format, args...))
}

func (r *report) sttCell(row, dev, val string) {
	if r.stt == nil {
		r.stt = map[string]map[string]string{}
	}
	if _, ok := r.stt[row]; !ok {
		r.stt[row] = map[string]string{}
		r.sttRows = append(r.sttRows, row)
	}
	r.stt[row][dev] = val
}

func (r *report) host(ctx context.Context) {
	q := func(name string, args ...string) string {
		out, err := exec.CommandContext(ctx, name, args...).Output()
		if err != nil {
			return "?"
		}
		return strings.TrimSpace(string(out))
	}
	r.hostLines = []string{
		"Chip: " + q("sysctl", "-n", "machdep.cpu.brand_string"),
		"Cores: " + q("sysctl", "-n", "hw.perflevel0.physicalcpu") + " performance + " +
			q("sysctl", "-n", "hw.perflevel1.physicalcpu") + " efficiency",
		"Memory (bytes): " + q("sysctl", "-n", "hw.memsize"),
		"macOS: " + q("sw_vers", "-productVersion"),
		"Engine pins (engine/pins.env): " + pins(),
		"Date: " + time.Now().Format(time.DateOnly),
	}
	r.envNote()
}

// envNote records the GGML_* and OX_SAY_* variables the engines inherit, so
// a reader can audit that the Metal column ran with no tuning in effect.
func (r *report) envNote() {
	var vars []string
	for _, kv := range os.Environ() {
		if k, _, _ := strings.Cut(kv, "="); strings.HasPrefix(k, "GGML_") || strings.HasPrefix(k, "OX_SAY_") {
			vars = append(vars, kv)
		}
	}
	slices.Sort(vars)
	if len(vars) == 0 {
		r.note("environment: no GGML_* or OX_SAY_* variables set")
		return
	}
	r.note("environment inherited by the engines: %s", strings.Join(vars, " "))
}

// pins reads the engine commits from engine/pins.env; run from the repo
// root that built the engines.
func pins() string {
	data, err := os.ReadFile(filepath.Join("engine", "pins.env"))
	if err != nil {
		return "?"
	}
	var out []string
	for _, l := range strings.Split(string(data), "\n") {
		if k, v, ok := strings.Cut(l, "="); ok && strings.HasSuffix(k, "_COMMIT") {
			out = append(out, k+"="+v[:min(len(v), shortSHA)])
		}
	}
	return strings.Join(out, ", ")
}

func (r *report) markdown() string {
	var b strings.Builder
	if len(r.partial) > 0 {
		b.WriteString("> **PARTIAL RUN — do not publish these numbers as a complete result.**\n")
		for _, p := range r.partial {
			fmt.Fprintf(&b, "> - %s\n", p)
		}
		b.WriteString("\n")
	}
	b.WriteString("### Host\n\n")
	for _, l := range r.hostLines {
		fmt.Fprintf(&b, "- %s\n", l)
	}
	b.WriteString("\n### Text-to-speech: tts-server (Qwen3-TTS) on Metal\n\n")
	b.WriteString("| Model | Voice | Language | Start (s) | First audio (ms) | RTF | Peak RSS (MB) | Peak footprint |\n")
	b.WriteString("|---|---|---|---|---|---|---|---|\n")
	for _, t := range r.tts {
		fmt.Fprintf(&b, "| %s | %s | %s | %.1f | %.0f | %.2f | %.0f | %s |\n",
			t.model, t.voice, t.lang, t.start.Seconds(), t.firstAudioMS, t.rtf, t.rssMB, t.footprint)
	}
	b.WriteString("\n### Speech-to-text: ox-stt, Parakeet TDT 0.6B v3 q8_0\n\n| Measurement |")
	for _, d := range devices {
		fmt.Fprintf(&b, " %s |", d.name)
	}
	b.WriteString("\n|---|")
	for range devices {
		b.WriteString("---|")
	}
	b.WriteString("\n")
	for _, row := range r.sttRows {
		fmt.Fprintf(&b, "| %s |", row)
		for _, d := range devices {
			v := r.stt[row][d.name]
			if v == "" {
				v = "—"
			}
			fmt.Fprintf(&b, " %s |", v)
		}
		b.WriteString("\n")
	}
	if r.singles {
		b.WriteString("\n† single run; every other latency row is the median of -runs warm runs.\n")
	}
	if len(r.notes) > 0 {
		b.WriteString("\n### Notes\n\n")
		for _, n := range r.notes {
			fmt.Fprintf(&b, "- %s\n", n)
		}
	}
	return b.String()
}

// median is the middle value (the upper one for an even count).
func median(xs []float64) float64 {
	s := slices.Clone(xs)
	slices.Sort(s)
	return s[len(s)/2]
}
