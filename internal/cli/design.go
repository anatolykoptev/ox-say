package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/daemon"
	"github.com/anatolykoptev/ox-say/internal/player"
)

const (
	voiceDesignUsage = `usage: ox-say voice design "<description>" -t "<text>" [-n 1..4] [--seed N] [--play]`
	voiceSaveUsage   = "usage: ox-say voice save <name> <take path> [--replace]"
	replaceFlag      = "--replace"
	playFlag         = "--play"
	voiceUsage       = "usage: ox-say voice add|design|save|ls|rm"
)

// cmdVoiceDesign asks the daemon for takes of a voice described in words and
// prints each take's path and seed plus the command that keeps one.
func cmdVoiceDesign(args []string, stdout, stderr io.Writer) int {
	play := false
	var rest []string
	for _, a := range args {
		if a == playFlag {
			play = true
			continue
		}
		rest = append(rest, a)
	}
	vals, pos, err := pullFlags(rest, "t", "n", "seed")
	if err != nil {
		outln(stderr, "ox-say:", err)
		return 2
	}
	if len(pos) != 1 || strings.TrimSpace(vals["t"]) == "" {
		outln(stderr, voiceDesignUsage)
		return 2
	}
	body := map[string]any{"description": pos[0], "text": vals["t"]}
	for key, flagName := range map[string]string{"takes": "n", "seed": "seed"} {
		if vals[flagName] == "" {
			continue
		}
		n, perr := strconv.ParseInt(vals[flagName], 10, 64)
		if perr != nil {
			outf(stderr, "ox-say: -%s wants a whole number, got %q\n", flagName, vals[flagName])
			return 2
		}
		body[key] = n
	}
	raw, err := postJSON(daemonURL()+"/v1/audio/voices/design", body)
	if err != nil {
		return failDaemon(stderr, err)
	}
	var res daemon.DesignResult
	if err := json.Unmarshal(raw, &res); err != nil || len(res.Takes) == 0 {
		outln(stderr, "ox-say: the daemon returned no takes")
		return 1
	}
	for i, t := range res.Takes {
		outf(stdout, "take %d  seed %d  %.1fs  %s%s\n", i+1, t.Seed, t.DurationS, t.Path, warningSuffix(t.Warning))
	}
	outln(stdout, "save one:")
	for _, t := range res.Takes {
		outf(stdout, "  ox-say voice save %s %s\n", t.SuggestedName, shellQuote(t.Path))
	}
	if play {
		for _, t := range res.Takes {
			if err := player.Play(context.Background(), t.Path); err != nil {
				outln(stderr, "ox-say:", err)
				return 1
			}
		}
	}
	return 0
}

// cmdVoiceSave keeps a design take under a voice name. The daemon alone
// decides what the voice records about itself.
func cmdVoiceSave(args []string, stdout, stderr io.Writer) int {
	replace := false
	var rest []string
	for _, a := range args {
		if a == replaceFlag {
			replace = true
			continue
		}
		rest = append(rest, a)
	}
	args = rest
	if len(args) != 2 {
		outln(stderr, voiceSaveUsage)
		return 2
	}
	take, err := filepath.Abs(args[1])
	if err != nil {
		outf(stderr, "ox-say: %v\n", err)
		return 2
	}
	raw, err := postJSON(daemonURL()+"/v1/audio/voices/design/save", map[string]any{"name": args[0], "take": take, "replace": replace})
	if err != nil {
		return failDaemon(stderr, err)
	}
	var res daemon.SaveDesignResult
	if json.Unmarshal(raw, &res) != nil {
		outln(stderr, "ox-say: unreadable answer from the daemon")
		return 1
	}
	outf(stdout, "voice %q saved (seed %d); use it with: ox-say say -v %s \"...\"\n", args[0], res.Seed, args[0])
	if res.Notice != "" {
		outf(stdout, "note: %s\n", res.Notice)
	}
	return 0
}

// shellQuote single-quotes s so the printed command pastes into a shell as is.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func warningSuffix(w string) string {
	if w == "" {
		return ""
	}
	return "  (warning: " + w + ")"
}

// outf and outln write a line to a terminal; a failed write has nowhere to be
// reported, so it is dropped here once.
func outf(w io.Writer, format string, a ...any) { _, _ = fmt.Fprintf(w, format, a...) }
func outln(w io.Writer, a ...any)               { _, _ = fmt.Fprintln(w, a...) }
