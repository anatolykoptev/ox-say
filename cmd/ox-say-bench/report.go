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
	runs      int      // -runs: how many warm runs each median is of
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

func (r *report) host(ctx context.Context, engineDir string) {
	q := func(name string, args ...string) string {
		out, err := exec.CommandContext(ctx, name, args...).Output()
		if err != nil {
			return "?"
		}
		return strings.TrimSpace(string(out))
	}
	r.hostLines = []string{
		"Chip: " + q("sysctl", "-n", "machdep.cpu.brand_string"),
		coresLine(q),
		"Memory (bytes): " + q("sysctl", "-n", "hw.memsize"),
		"macOS: " + q("sw_vers", "-productVersion"),
		"Engine pins (from the build stamp): " + pinsFrom(engineDir),
		"Date: " + time.Now().Format(time.DateOnly),
	}
	r.envNote()
}

// envNote records the GGML_* and OX_SAY_* variables the engines inherit, so
// a reader can audit that the Metal column ran with no tuning in effect.
func (r *report) envNote() { r.envNoteFrom(os.Environ()) }

// envNoteFrom prints GGML_* tuning as name=value and OX_SAY_* by name only: the
// note is committed, and an OX_SAY_* value can hold a URL with userinfo or a
// home path (OX_SAY_GET_URL).
func (r *report) envNoteFrom(environ []string) {
	var vars []string
	for _, kv := range environ {
		k, _, _ := strings.Cut(kv, "=")
		switch {
		case strings.HasPrefix(k, "GGML_"):
			vars = append(vars, kv)
		case strings.HasPrefix(k, "OX_SAY_"):
			vars = append(vars, k)
		}
	}
	slices.Sort(vars)
	if len(vars) == 0 {
		r.note("environment: no GGML_* or OX_SAY_* variables set")
		return
	}
	r.note("environment inherited by the engines: %s", strings.Join(vars, " "))
}

// coresLine is the host's core count: performance and efficiency cores on Apple
// Silicon, else the plain physical count.
func coresLine(q func(name string, args ...string) string) string {
	perf, eff := q("sysctl", "-n", "hw.perflevel0.physicalcpu"), q("sysctl", "-n", "hw.perflevel1.physicalcpu")
	if perf == "?" || perf == "" || eff == "?" || eff == "" {
		// Intel has no performance levels: say how many cores there are, not
		// "8 performance +  efficiency".
		return "Cores: " + q("sysctl", "-n", "hw.physicalcpu")
	}
	return "Cores: " + perf + " performance + " + eff + " efficiency"
}

// pinsFrom reads the engine commits from the pins.env stamp that engine/build.sh
// leaves next to the binaries: those are the commits the binaries under test were
// built from. The checkout's own engine/pins.env says what the NEXT build would
// use, which may not be what is in engineDir, so it is never a fallback.
func pinsFrom(engineDir string) string {
	data, err := os.ReadFile(filepath.Join(engineDir, "pins.env"))
	if err != nil {
		return "unknown (no pins.env next to the engine binaries; build them with engine/build.sh)"
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
		fmt.Fprintf(&b, "\n† single run; every other latency row is the median of %d warm runs.\n", r.runs)
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
