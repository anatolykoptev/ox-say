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
	voiceSaveUsage   = "usage: ox-say voice save <name> <take path>"
	playFlag         = "--play"
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
		fmt.Fprintln(stderr, "ox-say:", err)
		return 2
	}
	if len(pos) != 1 || strings.TrimSpace(vals["t"]) == "" {
		fmt.Fprintln(stderr, voiceDesignUsage)
		return 2
	}
	body := map[string]any{"description": pos[0], "text": vals["t"]}
	for key, flagName := range map[string]string{"takes": "n", "seed": "seed"} {
		if vals[flagName] == "" {
			continue
		}
		n, perr := strconv.ParseInt(vals[flagName], 10, 64)
		if perr != nil {
			fmt.Fprintf(stderr, "ox-say: -%s wants a whole number, got %q\n", flagName, vals[flagName])
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
		fmt.Fprintln(stderr, "ox-say: the daemon returned no takes")
		return 1
	}
	for i, t := range res.Takes {
		fmt.Fprintf(stdout, "take %d  seed %d  %.1fs  %s\n", i+1, t.Seed, t.DurationS, t.Path)
	}
	fmt.Fprintf(stdout, "save one: ox-say voice save <name> %s\n", shellQuote(res.Takes[0].Path))
	if play {
		for _, t := range res.Takes {
			if err := player.Play(context.Background(), t.Path); err != nil {
				fmt.Fprintln(stderr, "ox-say:", err)
				return 1
			}
		}
	}
	return 0
}

// cmdVoiceSave keeps a design take under a voice name. The daemon alone
// decides what the voice records about itself.
func cmdVoiceSave(args []string, stdout, stderr io.Writer) int {
	if len(args) != 2 {
		fmt.Fprintln(stderr, voiceSaveUsage)
		return 2
	}
	take, err := filepath.Abs(args[1])
	if err != nil {
		fmt.Fprintf(stderr, "ox-say: %v\n", err)
		return 2
	}
	raw, err := postJSON(daemonURL()+"/v1/audio/voices/design/save", map[string]any{"name": args[0], "take": take})
	if err != nil {
		return failDaemon(stderr, err)
	}
	var res daemon.SaveDesignResult
	if json.Unmarshal(raw, &res) != nil {
		fmt.Fprintln(stderr, "ox-say: unreadable answer from the daemon")
		return 1
	}
	fmt.Fprintf(stdout, "voice %q saved (seed %d); use it with: ox-say say -v %s \"...\"\n", args[0], res.Seed, args[0])
	if res.Notice != "" {
		fmt.Fprintf(stdout, "note: %s\n", res.Notice)
	}
	return 0
}

// shellQuote leaves a plain path as is and single-quotes anything else, so the
// printed command can be pasted.
func shellQuote(s string) string {
	for _, r := range s {
		plain := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("/._-+,:@%", r) || r > 127
		if !plain {
			return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
		}
	}
	return s
}
