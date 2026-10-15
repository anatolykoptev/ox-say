package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
)

// sayFlagNames are the flags `say` accepts; the quality ones are VoxCPM2's.
var sayFlagNames = []string{"v", "l", "f", "o", "m", "i", "seed", "cfg", "steps", "clone-mode", "loudness"}

// sayTextFlags maps a text flag to the speech field it sets.
var sayTextFlags = map[string]string{"m": "model", "i": "instructions", "clone-mode": "clone_mode"}

// addQualityFlags copies the VoxCPM2 flags that were given into body, numbers
// typed (a string would be a 400 from the daemon). A malformed number returns
// the plain message to print.
func addQualityFlags(body map[string]any, vals map[string]string) error {
	for flagName, field := range sayTextFlags {
		if vals[flagName] != "" {
			body[field] = vals[flagName]
		}
	}
	numbers := []struct {
		flagName, field string
		parse           func(string) (any, error)
	}{
		{"seed", "seed", func(s string) (any, error) { return strconv.ParseInt(s, 10, 64) }},
		{"cfg", "cfg_value", func(s string) (any, error) { return strconv.ParseFloat(s, 64) }},
		{"steps", "inference_timesteps", func(s string) (any, error) { return strconv.Atoi(s) }},
		{"loudness", "loudness_lufs", func(s string) (any, error) { return strconv.ParseFloat(s, 64) }},
	}
	for _, n := range numbers {
		raw, given := vals[n.flagName]
		if !given {
			continue
		}
		v, err := n.parse(raw)
		if err != nil {
			return fmt.Errorf("--%s %s: not a number", n.flagName, raw)
		}
		body[n.field] = v
	}
	return nil
}

// addVoiceMeta copies --engine, --style and --designed-from, when given, into body.
func addVoiceMeta(body map[string]any, vals map[string]string) {
	for flagName, field := range map[string]string{"engine": "engine", "style": "style", "designed-from": "designed_from"} {
		if v, ok := vals[flagName]; ok && v != "" {
			body[field] = v
		}
	}
}

const voiceSetUsage = `usage: ox-say voice set <name> [--engine qwen3-tts|voxcpm2|""] [--style "<delivery>"|""]`

// cmdVoiceSet changes a saved voice's preferred engine and/or default style.
// Only the flags that were given are sent; an empty value clears the field.
func cmdVoiceSet(args []string, stdout, stderr io.Writer) int {
	vals, pos, err := pullFlags(args, "engine", "style")
	if err != nil {
		outln(stderr, "ox-say:", err)
		return 2
	}
	body := map[string]any{}
	for _, k := range []string{"engine", "style"} {
		if v, ok := vals[k]; ok {
			body[k] = v
		}
	}
	if len(pos) != 1 || len(body) == 0 {
		outln(stderr, voiceSetUsage)
		return 2
	}
	if err := patchJSON(daemonURL()+"/v1/audio/voices/"+url.PathEscape(pos[0]), body); err != nil {
		return failDaemon(stderr, err)
	}
	outf(stdout, "voice %q updated\n", pos[0])
	return 0
}

// patchJSON PATCHes a JSON body and returns the daemon's error message, if any.
func patchJSON(target string, body map[string]any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPatch, target, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return daemonErr(err)
	}
	defer func() { _ = resp.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8192))
	if err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("daemon: %s: %s", resp.Status, extractErr(data))
	}
	return nil
}

// studioVoiceStatus is /status's voxcpm2 key.
type studioVoiceStatus struct {
	Available bool    `json:"available"`
	Reason    string  `json:"reason,omitempty"`
	State     string  `json:"state"`
	PID       int     `json:"pid,omitempty"`
	UptimeS   float64 `json:"uptime_s,omitempty"`
	LastErr   string  `json:"last_error,omitempty"`
}

// print writes the studio voice line: its state, or why it cannot run.
func (s *studioVoiceStatus) print(w io.Writer) {
	if !s.Available {
		outf(w, "studio voice (voxcpm2): unavailable: %s\n", s.Reason)
		return
	}
	outf(w, "studio voice (voxcpm2): %s", s.State)
	if s.PID != 0 {
		outf(w, " (pid %d, up %.0fs)", s.PID, s.UptimeS)
	}
	outln(w)
	if s.LastErr != "" {
		outf(w, "studio voice last error: %s\n", s.LastErr)
	}
}
