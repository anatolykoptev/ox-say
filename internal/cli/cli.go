// Package cli implements the ox-say command line: `serve` runs the daemon;
// `say`, `voice` and `status` are thin HTTP clients of a running daemon.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/daemon"
	"github.com/anatolykoptev/ox-say/internal/player"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Run dispatches a subcommand and returns the exit code.
func Run(args []string, stdout, stderr io.Writer, version string) int {
	if len(args) == 0 {
		usage(stderr)
		return 2
	}
	switch args[0] {
	case "serve":
		return cmdServe(args[1:], stderr, version)
	case "say":
		return cmdSay(args[1:], stdout, stderr)
	case "voice":
		return cmdVoice(args[1:], stdout, stderr)
	case "transcribe":
		return cmdTranscribe(args[1:], stdout, stderr)
	case "status":
		return cmdStatus(args[1:], stdout, stderr)
	case "-h", "--help", "help":
		usage(stdout)
		return 0
	default:
		fmt.Fprintf(stderr, "unknown command %q\n", args[0])
		usage(stderr)
		return 2
	}
}

func usage(w io.Writer) {
	fmt.Fprint(w, `ox-say — local text-to-speech for Intel Macs

Usage:
  ox-say serve [flags]                  run the daemon (launchd starts this)
  ox-say say [-v v] [-l lang] [-f fmt] [-o path] [text...]
  ox-say voice add <name> <audio> [--ref-text t]
  ox-say voice ls
  ox-say voice rm <name>
  ox-say transcribe [-e parakeet|whisper] [-l lang] [--prompt t] [--json|--srt] <file>
  ox-say status

Flags for serve (env vars are the defaults; flags override):
`)
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(w)
	config.RegisterFlags(fs)
	fs.PrintDefaults()
	fmt.Fprint(w, `
say flags:
  -v voice      cloned voice name
  -l language   e.g. Russian, English (default: engine auto)
  -f format     wav | mp3 | opus (default: wav; used for -o and playback)
  -o path       write file instead of playing it

transcribe flags:
  -e engine     parakeet (default) | whisper
  -l language   whisper language hint (parakeet auto-detects)
  --prompt t    whisper initial prompt
  --json        print the full result as JSON (ox_json: text, segments, words as w/s/e/p)
  --srt         print an SRT subtitle file

Without -o, say plays the audio like macOS say.
`)
}

// cmdServe loads config, builds the daemon, and hands the HTTP+MCP surface
// to go-mcpserver.
func cmdServe(args []string, stderr io.Writer, version string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	config.RegisterFlags(fs)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	cfg, err := config.Load(fs)
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 2
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	d, err := daemon.New(cfg, logger)
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 2
	}
	daemon.SetVersion(version)

	err = mcpserver.Serve(&mcp.Implementation{
		Name:    "ox-say",
		Version: version,
	}, d.ServerConfig(version), d.RegisterTools)
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	return 0
}

// daemonURL is where the CLI finds the daemon.
func daemonURL() string {
	addr := os.Getenv("OX_SAY_ADDR")
	if addr == "" {
		addr = config.DefaultAddr
	}
	return "http://" + addr
}

var errDaemonDown = errors.New("daemon not running")

// httpClient bounds only the connect: a refused socket must fail fast, but a
// request may legitimately sit in the server for the whole cold-start window
// plus synthesis, so there is no total timeout.
var httpClient = &http.Client{
	Transport: &http.Transport{
		DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
	},
}

func daemonErr(err error) error {
	if errors.Is(err, syscall.ECONNREFUSED) || strings.Contains(err.Error(), "connection refused") {
		return errDaemonDown
	}
	return err
}

func failDaemon(stderr io.Writer, err error) int {
	if errors.Is(err, errDaemonDown) {
		fmt.Fprintln(stderr, "ox-say: daemon is not running — start it with `ox-say serve`")
		return 1
	}
	fmt.Fprintln(stderr, "ox-say:", err)
	return 1
}

// pullFlags extracts "-name value", "-name=value", "--name value" and
// "--name=value" occurrences for the given flag names, wherever they appear
// in args. Everything else (and anything after "--") is returned as
// positionals. Go's flag package stops at the first positional, which would
// silently swallow trailing flags into `say` text or reject `voice add`'s
// documented flag-after-positionals form.
func pullFlags(args []string, names ...string) (vals map[string]string, positional []string, err error) {
	vals = map[string]string{}
	want := map[string]bool{}
	for _, n := range names {
		want[n] = true
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}
		name, val, isFlag, hasEq := "", "", false, false
		for _, p := range []string{"--", "-"} {
			if rest, ok := strings.CutPrefix(a, p); ok && rest != "" {
				if k, v, eq := strings.Cut(rest, "="); eq {
					name, val, isFlag, hasEq = k, v, true, true
				} else {
					name, isFlag = rest, true
				}
				break
			}
		}
		if !isFlag || !want[name] {
			positional = append(positional, a)
			continue
		}
		if !hasEq {
			i++
			if i >= len(args) {
				return nil, nil, fmt.Errorf("flag -%s needs a value", name)
			}
			val = args[i]
		}
		vals[name] = val
	}
	return vals, positional, nil
}

// cmdSay synthesizes text and either writes it to -o or plays it.
func cmdSay(args []string, stdout, stderr io.Writer) int {
	vals, pos, err := pullFlags(args, "v", "l", "f", "o")
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 2
	}
	var text string
	if len(pos) > 0 {
		text = strings.Join(pos, " ")
	} else {
		if st, _ := os.Stdin.Stat(); st != nil && st.Mode()&os.ModeCharDevice != 0 {
			fmt.Fprintln(stderr, "ox-say: nothing to say — pass text or pipe stdin")
			return 2
		}
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintln(stderr, "ox-say: stdin:", err)
			return 1
		}
		text = strings.TrimSpace(string(b))
	}
	if text == "" {
		fmt.Fprintln(stderr, "ox-say: nothing to say — pass text or pipe stdin")
		return 2
	}
	reqFormat := vals["f"]
	if reqFormat == "" {
		// Infer the format from the -o extension; default wav.
		reqFormat = "wav"
		switch strings.ToLower(filepath.Ext(vals["o"])) {
		case ".mp3":
			reqFormat = "mp3"
		case ".opus", ".ogg":
			reqFormat = "opus"
		case ".pcm":
			reqFormat = "pcm"
		}
	}
	switch reqFormat {
	case "wav", "mp3", "opus", "pcm":
	default:
		fmt.Fprintf(stderr, "ox-say: unsupported format %q (want wav|mp3|opus|pcm)\n", reqFormat)
		return 2
	}
	out := vals["o"]
	if out == "" && reqFormat == "opus" {
		fmt.Fprintln(stderr, "ox-say: opus produces an .ogg file afplay cannot play — use -o to write it")
		return 2
	}
	body := map[string]any{
		"input":           text,
		"response_format": reqFormat,
	}
	if vals["v"] != "" {
		body["voice"] = vals["v"]
	}
	if vals["l"] != "" {
		body["language"] = vals["l"]
	}
	audio, err := postJSON(daemonURL()+"/v1/audio/speech", body)
	if err != nil {
		return failDaemon(stderr, err)
	}
	if out != "" {
		if err := os.WriteFile(out, audio, 0o644); err != nil {
			fmt.Fprintln(stderr, "ox-say:", err)
			return 1
		}
		fmt.Fprintln(stdout, out)
		return 0
	}
	// Play like macOS say: write a temp file, run the platform player.
	ext := "." + reqFormat
	if reqFormat == "opus" {
		ext = ".ogg"
	}
	tmp, err := os.CreateTemp("", "ox-say-*"+ext)
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(audio); err != nil {
		_ = tmp.Close()
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	_ = tmp.Close()
	if err := player.Play(context.Background(), tmp.Name()); err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	return 0
}

// postJSON POSTs a JSON body and returns the response bytes or an
// error carrying the daemon's error message.
func postJSON(url string, body map[string]any) ([]byte, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	resp, err := httpClient.Post(url, "application/json", strings.NewReader(string(raw)))
	if err != nil {
		return nil, daemonErr(err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 256<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("daemon: %s: %s", resp.Status, extractErr(data))
	}
	return data, nil
}

// extractErr pulls "error.message" out of a JSON error body if present.
func extractErr(body []byte) string {
	var v struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &v) == nil && v.Error.Message != "" {
		return v.Error.Message
	}
	return strings.TrimSpace(string(body))
}

func cmdVoice(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: ox-say voice add|ls|rm")
		return 2
	}
	switch args[0] {
	case "add":
		vals, pos, err := pullFlags(args[1:], "ref-text")
		if err != nil {
			fmt.Fprintln(stderr, "ox-say:", err)
			return 2
		}
		if len(pos) != 2 {
			fmt.Fprintln(stderr, "usage: ox-say voice add <name> <audio> [--ref-text t]")
			return 2
		}
		// The daemon's cwd is "/" under launchd — resolve the clip path
		// against the CLI's cwd before sending it.
		abs, err := filepath.Abs(pos[1])
		if err != nil {
			fmt.Fprintf(stderr, "ox-say: %v\n", err)
			return 2
		}
		_, err = postJSON(daemonURL()+"/v1/audio/voices", map[string]any{
			"name":       pos[0],
			"audio_path": abs,
			"ref_text":   vals["ref-text"],
		})
		if err != nil {
			return failDaemon(stderr, err)
		}
		fmt.Fprintf(stdout, "voice %q added\n", pos[0])
		return 0
	case "ls":
		resp, err := httpClient.Get(daemonURL() + "/v1/audio/voices")
		if err != nil {
			return failDaemon(stderr, daemonErr(err))
		}
		defer resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
			fmt.Fprintln(stderr, "ox-say:", extractErr(body))
			return 1
		}
		var list struct {
			Voices []struct {
				Name    string `json:"name"`
				RefText string `json:"ref_text,omitempty"`
				Created string `json:"created"`
			} `json:"voices"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
			fmt.Fprintln(stderr, "ox-say:", err)
			return 1
		}
		for _, v := range list.Voices {
			mark := ""
			if v.RefText != "" {
				mark = " (ref_text)"
			}
			fmt.Fprintf(stdout, "%s%s\n", v.Name, mark)
		}
		return 0
	case "rm":
		if len(args) != 2 {
			fmt.Fprintln(stderr, "usage: ox-say voice rm <name>")
			return 2
		}
		req, err := http.NewRequest(http.MethodDelete, daemonURL()+"/v1/audio/voices/"+url.PathEscape(args[1]), nil)
		if err != nil {
			fmt.Fprintln(stderr, "ox-say:", err)
			return 1
		}
		resp, err := httpClient.Do(req)
		if err != nil {
			return failDaemon(stderr, daemonErr(err))
		}
		defer resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
			fmt.Fprintln(stderr, "ox-say:", extractErr(body))
			return 1
		}
		fmt.Fprintf(stdout, "voice %q removed\n", args[1])
		return 0
	default:
		fmt.Fprintln(stderr, "usage: ox-say voice add|ls|rm")
		return 2
	}
}

// cmdTranscribe uploads a local file to the daemon's transcriptions route as
// multipart and prints the transcript (text by default; --json and --srt
// select ox_json and srt server-side).
func cmdTranscribe(args []string, stdout, stderr io.Writer) int {
	var jsonOut, srtOut bool
	var rest []string
	for _, a := range args {
		switch a {
		case "--json":
			jsonOut = true
		case "--srt":
			srtOut = true
		default:
			rest = append(rest, a)
		}
	}
	vals, pos, err := pullFlags(rest, "e", "l", "prompt")
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 2
	}
	switch vals["e"] {
	case "", "parakeet", "whisper":
	default:
		fmt.Fprintf(stderr, "ox-say: unsupported engine %q (want parakeet|whisper)\n", vals["e"])
		return 2
	}
	if len(pos) != 1 {
		fmt.Fprintln(stderr, "usage: ox-say transcribe [-e parakeet|whisper] [-l lang] [--prompt t] [--json|--srt] <file>")
		return 2
	}
	if jsonOut && srtOut {
		fmt.Fprintln(stderr, "ox-say transcribe: --json and --srt are exclusive")
		return 2
	}
	f, err := os.Open(pos[0])
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	defer f.Close()

	format := "text"
	if jsonOut {
		format = "ox_json" // ox-stt's own shape: words as w/s/e/p
	}
	if srtOut {
		format = "srt"
	}

	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		err := func() error {
			fw, err := mw.CreateFormFile("file", filepath.Base(pos[0]))
			if err != nil {
				return err
			}
			if _, err := io.Copy(fw, f); err != nil {
				return err
			}
			for _, kv := range [][2]string{
				{"model", vals["e"]},
				{"language", vals["l"]},
				{"prompt", vals["prompt"]},
				{"response_format", format},
			} {
				if kv[1] == "" {
					continue
				}
				if err := mw.WriteField(kv[0], kv[1]); err != nil {
					return err
				}
			}
			return mw.Close()
		}()
		_ = pw.CloseWithError(err)
	}()
	req, err := http.NewRequest(http.MethodPost, daemonURL()+"/v1/audio/transcriptions", pr)
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := httpClient.Do(req)
	if err != nil {
		return failDaemon(stderr, daemonErr(err))
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	if resp.StatusCode/100 != 2 {
		return failDaemon(stderr, fmt.Errorf("daemon: %s: %s", resp.Status, extractErr(data)))
	}
	if _, err := stdout.Write(data); err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	if len(data) > 0 && data[len(data)-1] != '\n' {
		fmt.Fprintln(stdout)
	}
	return 0
}

func cmdStatus(_ []string, stdout, stderr io.Writer) int {
	resp, err := httpClient.Get(daemonURL() + "/status")
	if err != nil {
		return failDaemon(stderr, daemonErr(err))
	}
	defer resp.Body.Close()
	var st struct {
		Engine struct {
			State    string  `json:"state"`
			PID      int     `json:"pid,omitempty"`
			UptimeS  float64 `json:"uptime_s,omitempty"`
			LastErr  string  `json:"last_error,omitempty"`
			Starts   int     `json:"starts"`
			Restarts int     `json:"restarts"`
		} `json:"engine"`
		Voices []struct {
			Name string `json:"name"`
		} `json:"voices"`
		Version string `json:"version"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	fmt.Fprintf(stdout, "engine: %s", st.Engine.State)
	if st.Engine.PID != 0 {
		fmt.Fprintf(stdout, " (pid %d, up %.0fs)", st.Engine.PID, st.Engine.UptimeS)
	}
	fmt.Fprintln(stdout)
	fmt.Fprintf(stdout, "starts: %d, crash restarts: %d\n", st.Engine.Starts, st.Engine.Restarts)
	if st.Engine.LastErr != "" {
		fmt.Fprintf(stdout, "last error: %s\n", st.Engine.LastErr)
	}
	names := make([]string, 0, len(st.Voices))
	for _, v := range st.Voices {
		names = append(names, v.Name)
	}
	fmt.Fprintf(stdout, "voices: %s\n", strings.Join(names, ", "))
	fmt.Fprintf(stdout, "version: %s\n", st.Version)
	return 0
}
