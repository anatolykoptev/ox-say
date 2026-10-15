package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Exit codes of the produce commands that wait for a project.
const (
	exitDone   = 0
	exitFailed = 1
	exitUsage  = 2
	exitReview = 3 // the file is ready, some chunks need a listen
)

const (
	// maxScriptBytes bounds a script read from a file or stdin (the daemon's
	// own body limit is the same 1 MiB).
	maxScriptBytes = 1 << 20
	// produceReadLimit bounds one daemon answer.
	produceReadLimit = 8 << 20
	defaultRegen     = 2
	secondsPerMinute = 60
	producePath      = "/v1/produce"
	// producePollInterval is how often the CLI asks the daemon for progress.
	producePollInterval = time.Second
)

// Project statuses as the daemon reports them (vproject.Status*).
const (
	statusRunning     = "running"
	statusWaitingDict = "waiting_for_dictation"
	statusOnBattery   = "paused_on_battery"
	statusReview      = "review"
	statusDone        = "done"
	statusFailed      = "failed"
	statusCancelled   = "cancelled"
	statusInterrupted = "interrupted"
)

const produceUsage = `usage:
  ox-say produce <script.txt|-> [-v voice] [-i style] [-t title] [-o out.wav]
                 [--preset youtube|reels|voice-under-music] [--seed N] [--takes 1..3]
                 [--overwrite] [--allow-battery] [--no-wait]
  ox-say produce status <id> [--chunk N]
  ox-say produce resume <id> [--allow-battery] [--no-wait]
  ox-say produce cancel <id>
  ox-say produce chunk <id> <n> (--regen N | --pick KEY | --text "…") [--no-wait]
  ox-say produce rm [--delete-outputs] <id>
  ox-say produce ls`

// produceFlags are the flags that carry a value; the rest are switches.
var (
	produceValueFlags  = []string{"v", "i", "t", "o", "preset", "seed", "takes", "chunk", "regen", "pick", "text"}
	produceSwitchNames = []string{"overwrite", "allow-battery", "no-wait", "delete-outputs"}
)

// apiError is a non-2xx answer of the daemon.
type apiError struct {
	status    int
	message   string
	runningID string
}

func (e *apiError) Error() string { return fmt.Sprintf("daemon: %d: %s", e.status, e.message) }

// produceCall sends one request to the daemon and returns the body of a 2xx
// answer.
func produceCall(method, path string, body any) ([]byte, error) {
	var rd io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, daemonURL()+path, rd)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, daemonErr(err)
	}
	defer func() { _ = resp.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(resp.Body, produceReadLimit))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		ae := &apiError{status: resp.StatusCode, message: extractErr(data)}
		var v struct {
			RunningID string `json:"running_id"`
		}
		if json.Unmarshal(data, &v) == nil {
			ae.runningID = v.RunningID
		}
		return nil, ae
	}
	return data, nil
}

// failProduce prints err for the person and returns the exit code.
func failProduce(stderr io.Writer, err error) int {
	var ae *apiError
	if errors.As(err, &ae) {
		outln(stderr, "ox-say:", ae.message)
		if ae.runningID != "" {
			outln(stderr, "running:", ae.runningID)
		}
		return exitFailed
	}
	return failDaemon(stderr, err)
}

// projectSummary is the daemon's status view of a project.
type projectSummary struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Status   string `json:"status"`
	Error    string `json:"error"`
	Seed     int64  `json:"seed"`
	Progress struct {
		ChunksTotal int     `json:"chunks_total"`
		ChunksDone  int     `json:"chunks_done"`
		ETAS        float64 `json:"eta_s"`
	} `json:"progress"`
	Outputs struct {
		WAV       string  `json:"wav"`
		SRT       string  `json:"srt"`
		VTT       string  `json:"vtt"`
		Words     string  `json:"words_json"`
		Manifest  string  `json:"manifest_export"`
		DurationS float64 `json:"duration_s"`
	} `json:"outputs"`
	Chunks []struct {
		Index   int      `json:"index"`
		Status  string   `json:"status"`
		Pick    string   `json:"pick"`
		Reasons []string `json:"reasons"`
	} `json:"chunks"`
	Notes []string `json:"notes"`
}

func (s *projectSummary) active() bool {
	switch s.Status {
	case statusRunning, statusWaitingDict, statusOnBattery:
		return true
	}
	return false
}

func failedStatus(status string) bool {
	return status == statusFailed || status == statusCancelled || status == statusInterrupted
}

// exitCode maps a final status: 0 done, 3 review, 1 anything else.
func exitCode(status string) int {
	switch status {
	case statusDone:
		return exitDone
	case statusReview:
		return exitReview
	}
	return exitFailed
}

func decodeSummary(data []byte) (projectSummary, error) {
	var s projectSummary
	if err := json.Unmarshal(data, &s); err != nil {
		return s, fmt.Errorf("unreadable answer from the daemon: %w", err)
	}
	return s, nil
}

// cmdProduce dispatches `ox-say produce …`; poll is the wait between status
// requests (the Run case passes a second).
func cmdProduce(args []string, stdout, stderr io.Writer, poll time.Duration) int {
	vals, pos, err := pullFlags(args, produceValueFlags...)
	if err != nil {
		outln(stderr, "ox-say:", err)
		return exitUsage
	}
	switches := map[string]bool{}
	pos = pullSwitches(pos, switches)
	if len(pos) == 0 {
		outln(stderr, produceUsage)
		return exitUsage
	}
	c := &produceCmd{vals: vals, sw: switches, out: stdout, err: stderr, poll: poll}
	switch pos[0] {
	case "ls":
		return c.list()
	case "status":
		return c.status(pos[1:])
	case "resume":
		return c.resume(pos[1:])
	case "cancel":
		return c.cancel(pos[1:])
	case "rm":
		return c.remove(pos[1:])
	case "chunk":
		return c.chunk(pos[1:])
	}
	return c.create(pos)
}

// pullSwitches removes the value-less switches from pos and records them.
func pullSwitches(pos []string, into map[string]bool) []string {
	rest := make([]string, 0, len(pos))
	for _, a := range pos {
		name := strings.TrimLeft(a, "-")
		known := false
		for _, s := range produceSwitchNames {
			if name == s && strings.HasPrefix(a, "-") {
				known = true
			}
		}
		if known {
			into[name] = true
			continue
		}
		rest = append(rest, a)
	}
	return rest
}

type produceCmd struct {
	vals map[string]string
	sw   map[string]bool
	out  io.Writer
	err  io.Writer
	poll time.Duration
}

// readScript reads the script from a file or, for "-", from stdin.
func readScript(arg string) (string, error) {
	var r io.Reader = os.Stdin
	if arg != "-" {
		f, err := os.Open(arg)
		if err != nil {
			return "", err
		}
		defer func() { _ = f.Close() }()
		r = f
	}
	b, err := io.ReadAll(io.LimitReader(r, maxScriptBytes+1))
	if err != nil {
		return "", err
	}
	if len(b) > maxScriptBytes {
		return "", fmt.Errorf("the script is longer than %d MiB", maxScriptBytes>>20)
	}
	return string(b), nil
}

// createBody builds POST /v1/produce from the flags, numbers typed.
func (c *produceCmd) createBody(script string) (map[string]any, error) {
	body := map[string]any{"script": script}
	for flagName, field := range map[string]string{"v": "voice", "i": "style", "t": "title", "preset": "preset"} {
		if c.vals[flagName] != "" {
			body[field] = c.vals[flagName]
		}
	}
	if o := c.vals["o"]; o != "" {
		abs, err := filepath.Abs(o) // the daemon's working directory is not ours
		if err != nil {
			return nil, err
		}
		body["out_path"] = abs
	}
	for _, n := range []string{"seed", "takes"} {
		raw, given := c.vals[n]
		if !given {
			continue
		}
		v, err := parseNumber(raw, true)
		if err != nil {
			return nil, fmt.Errorf("--%s %s: %w", n, raw, err)
		}
		body[n] = v
	}
	for sw, field := range map[string]string{"overwrite": "overwrite", "allow-battery": "allow_battery"} {
		if c.sw[sw] {
			body[field] = true
		}
	}
	return body, nil
}

func (c *produceCmd) create(pos []string) int {
	script, err := readScript(pos[0])
	if err != nil {
		outln(c.err, "ox-say:", err)
		return exitUsage
	}
	body, err := c.createBody(script)
	if err != nil {
		outln(c.err, "ox-say:", err)
		return exitUsage
	}
	data, err := produceCall(http.MethodPost, producePath, body)
	if err != nil {
		return failProduce(c.err, err)
	}
	return c.follow(data)
}

// follow takes the daemon's answer to a request that started a run, and
// either reports it (--no-wait) or waits for the end.
func (c *produceCmd) follow(data []byte) int {
	s, err := decodeSummary(data)
	if err != nil {
		outln(c.err, "ox-say:", err)
		return exitFailed
	}
	if c.sw["no-wait"] {
		outf(c.out, "%s\ncheck on it: ox-say produce status %s\n", s.ID, s.ID)
		return exitDone
	}
	final, err := c.wait(s.ID)
	if err != nil {
		outf(c.err, "ox-say: lost contact with the daemon; the voiceover keeps going. Check: ox-say produce status %s\n", s.ID)
		return failProduce(c.err, err)
	}
	c.report(&final)
	return exitCode(final.Status)
}

// wait polls the project until it is no longer running. On a terminal the
// progress line rewrites itself; anywhere else (a log, a pipe) each change is
// its own line.
func (c *produceCmd) wait(id string) (projectSummary, error) {
	tty := isTerminal(c.err)
	last := ""
	for {
		time.Sleep(c.poll)
		data, err := produceCall(http.MethodGet, producePath+"/"+url.PathEscape(id), nil)
		if err != nil {
			return projectSummary{}, err
		}
		s, err := decodeSummary(data)
		if err != nil {
			return s, err
		}
		line := progressLine(&s, id)
		if !s.active() {
			if tty && last != "" {
				outf(c.err, "\r%s\r", strings.Repeat(" ", len(last)))
			}
			return s, nil
		}
		switch {
		case tty:
			outf(c.err, "\r%s", line)
		case line != last:
			outln(c.err, line)
		}
		last = line
	}
}

// isTerminal reports whether w is a character device (a terminal).
func isTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

// progressLine is the one status line shown while waiting.
func progressLine(s *projectSummary, id string) string {
	line := fmt.Sprintf("%s · chunk %d/%d", statusWords(s.Status, id), s.Progress.ChunksDone, s.Progress.ChunksTotal)
	if s.Progress.ETAS > 0 {
		line += fmt.Sprintf(" · ~%s left", etaText(s.Progress.ETAS))
	}
	return line
}

func statusWords(status, id string) string {
	switch status {
	case statusWaitingDict:
		return "waiting for dictation"
	case statusOnBattery:
		return "paused: on battery — plug in or run: ox-say produce resume " + id + " --allow-battery"
	}
	return status
}

func etaText(sec float64) string {
	if sec < secondsPerMinute {
		return fmt.Sprintf("%.0f s", sec)
	}
	return fmt.Sprintf("%.0f min", sec/secondsPerMinute)
}

// report prints the end of a run: seed and notes (stderr, as `say` prints
// them), then the files and the chunks to listen to (stdout).
func (c *produceCmd) report(s *projectSummary) {
	writeSeedWarning(c.err, strconv.FormatInt(s.Seed, 10), strings.Join(s.Notes, "; "))
	if failedStatus(s.Status) {
		msg := s.Status
		if s.Error != "" {
			msg += ": " + s.Error
		}
		outln(c.err, "ox-say: voiceover "+msg)
		if s.Status == statusInterrupted {
			outf(c.err, "continue with: ox-say produce resume %s\n", s.ID)
		}
	}
	for _, p := range []string{s.Outputs.WAV, s.Outputs.SRT, s.Outputs.VTT, s.Outputs.Words, s.Outputs.Manifest} {
		if p != "" {
			outln(c.out, p)
		}
	}
	for _, ch := range s.Chunks {
		if ch.Status != statusReview {
			continue
		}
		outf(c.out, "chunk %d: %s — listen: ox-say produce status %s --chunk %d\n", ch.Index, strings.Join(ch.Reasons, "; "), s.ID, ch.Index)
		outf(c.out, "  regenerate: ox-say produce chunk %s %d --regen %d\n", s.ID, ch.Index, defaultRegen)
	}
}

func (c *produceCmd) idArg(pos []string) (string, bool) {
	if len(pos) != 1 {
		outln(c.err, produceUsage)
		return "", false
	}
	return pos[0], true
}

func (c *produceCmd) status(pos []string) int {
	id, ok := c.idArg(pos)
	if !ok {
		return exitUsage
	}
	if raw, given := c.vals["chunk"]; given {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 {
			outf(c.err, "ox-say: --chunk %s: not a chunk number\n", raw)
			return exitUsage
		}
		d, err := fetchChunk(id, n)
		if err != nil {
			return failProduce(c.err, err)
		}
		d.print(c.out, id, n)
		return exitDone
	}
	data, err := produceCall(http.MethodGet, producePath+"/"+url.PathEscape(id), nil)
	if err != nil {
		return failProduce(c.err, err)
	}
	s, err := decodeSummary(data)
	if err != nil {
		outln(c.err, "ox-say:", err)
		return exitFailed
	}
	outf(c.out, "%s: %s · chunk %d/%d\n", s.ID, statusWords(s.Status, s.ID), s.Progress.ChunksDone, s.Progress.ChunksTotal)
	c.report(&s)
	return exitDone
}

func (c *produceCmd) resume(pos []string) int {
	id, ok := c.idArg(pos)
	if !ok {
		return exitUsage
	}
	body := map[string]any{}
	if c.sw["allow-battery"] {
		body["allow_battery"] = true
	}
	data, err := produceCall(http.MethodPost, producePath+"/"+url.PathEscape(id)+"/resume", body)
	if err != nil {
		return failProduce(c.err, err)
	}
	return c.follow(data)
}

func (c *produceCmd) cancel(pos []string) int {
	id, ok := c.idArg(pos)
	if !ok {
		return exitUsage
	}
	if _, err := produceCall(http.MethodPost, producePath+"/"+url.PathEscape(id)+"/cancel", nil); err != nil {
		return failProduce(c.err, err)
	}
	outf(c.out, "cancelling %s: the take being rendered finishes and is kept\n", id)
	return exitDone
}

func (c *produceCmd) remove(pos []string) int {
	id, ok := c.idArg(pos)
	if !ok {
		return exitUsage
	}
	path := producePath + "/" + url.PathEscape(id)
	if c.sw["delete-outputs"] {
		path += "?delete_outputs=true"
	}
	if _, err := produceCall(http.MethodDelete, path, nil); err != nil {
		return failProduce(c.err, err)
	}
	outf(c.out, "removed %s\n", id)
	return exitDone
}

func (c *produceCmd) list() int {
	data, err := produceCall(http.MethodGet, producePath, nil)
	if err != nil {
		return failProduce(c.err, err)
	}
	var v struct {
		Projects []projectSummary `json:"projects"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		outln(c.err, "ox-say: unreadable answer from the daemon:", err)
		return exitFailed
	}
	if len(v.Projects) == 0 {
		outln(c.out, "no voiceover projects")
	}
	for _, p := range v.Projects {
		outf(c.out, "%s  %-12s  chunk %d/%d  %s\n", p.ID, p.Status, p.Progress.ChunksDone, p.Progress.ChunksTotal, p.Title)
	}
	return exitDone
}
