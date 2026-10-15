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

	"golang.org/x/sys/unix"
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
	// maxTakes is the daemon's limit on takes per chunk.
	maxTakes = 3
	// pollRetries is how many failed status requests in a row end the wait.
	pollRetries = 3
	// defaultTermWidth is used when the terminal size cannot be read.
	defaultTermWidth = 80
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

// verbSpec is what one produce verb accepts: how many positionals follow the
// verb and which flags apply. Everything else is a usage error that names the
// token (a typo must not be dropped silently).
type verbSpec struct {
	args     int
	values   []string
	switches []string
}

// createSpec is `ox-say produce <script>`: any word that is not a verb names a script.
var createSpec = verbSpec{args: 1, values: []string{"v", "i", "t", "o", "preset", "seed", "takes"},
	switches: []string{"overwrite", "allow-battery", "no-wait"}}

var produceVerbs = map[string]verbSpec{
	"ls":     {},
	"status": {args: 1, values: []string{"chunk"}},
	"resume": {args: 1, switches: []string{"allow-battery", "no-wait"}},
	"cancel": {args: 1},
	"rm":     {args: 1, switches: []string{"delete-outputs"}},
	"chunk":  {args: 2, values: []string{"regen", "pick", "text"}, switches: []string{"no-wait"}},
}

// flagText is a flag as the person typed it.
func flagText(name string) string {
	if len(name) == 1 {
		return "-" + name
	}
	return "--" + name
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// checkUsage rejects flags that do not belong to the verb, unknown "-" tokens
// and a wrong number of arguments; it returns the message to print.
func checkUsage(verb string, spec verbSpec, vals map[string]string, sw map[string]bool, args []string) string {
	for name := range vals {
		if !contains(spec.values, name) {
			return fmt.Sprintf("%s does not apply to produce %s", flagText(name), verb)
		}
	}
	for name := range sw {
		if !contains(spec.switches, name) {
			return fmt.Sprintf("%s does not apply to produce %s", flagText(name), verb)
		}
	}
	for _, a := range args {
		if strings.HasPrefix(a, "-") && a != "-" {
			return fmt.Sprintf("unknown flag %s (see ox-say help)", a)
		}
	}
	if len(args) != spec.args {
		return fmt.Sprintf("produce %s takes %d argument(s), got %d: %s", verb, spec.args, len(args), strings.Join(args, " "))
	}
	return ""
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
	verb, rest := pos[0], pos[1:]
	spec, known := produceVerbs[verb]
	if !known {
		verb, rest, spec = "create", pos, createSpec
	}
	if msg := checkUsage(verb, spec, vals, switches, rest); msg != "" {
		outln(stderr, "ox-say:", msg)
		return exitUsage
	}
	c := &produceCmd{vals: vals, sw: switches, out: stdout, err: stderr, poll: poll}
	switch verb {
	case "ls":
		return c.list()
	case "status":
		return c.status(rest)
	case "resume":
		return c.resume(rest)
	case "cancel":
		return c.cancel(rest)
	case "rm":
		return c.remove(rest)
	case "chunk":
		return c.chunk(rest)
	}
	return c.create(rest)
}

// pullSwitches removes the value-less switches from pos and records them.
func pullSwitches(pos []string, into map[string]bool) []string {
	rest := make([]string, 0, len(pos))
	for _, a := range pos {
		name := strings.TrimLeft(a, "-")
		if strings.HasPrefix(a, "-") && contains(produceSwitchNames, name) {
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
	if arg == "-" {
		return readScriptFrom(os.Stdin)
	}
	f, err := os.Open(arg)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	return readScriptFrom(f)
}

// readScriptFrom reads at most maxScriptBytes; one byte more is an error.
func readScriptFrom(r io.Reader) (string, error) {
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
		if n == "takes" && (v.(int64) < 1 || v.(int64) > maxTakes) {
			return nil, fmt.Errorf("--takes %s: must be 1 to %d", raw, maxTakes)
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
	code, _ := c.follow(data)
	return code
}

// follow takes the daemon's answer to a request that started a run, and
// either reports it (--no-wait) or waits for the end. It returns the exit code
// and the final summary (nil when the run was not waited for or contact was lost).
func (c *produceCmd) follow(data []byte) (int, *projectSummary) {
	s, err := decodeSummary(data)
	if err != nil {
		outln(c.err, "ox-say:", err)
		return exitFailed, nil
	}
	if c.sw["no-wait"] {
		outf(c.out, "%s\ncheck on it: ox-say produce status %s\n", s.ID, s.ID)
		return exitDone, nil
	}
	final, err := c.wait(s.ID)
	if err != nil {
		var ae *apiError
		if errors.As(err, &ae) && ae.status == http.StatusNotFound {
			outf(c.err, "ox-say: the project %s was removed while waiting\n", s.ID)
			return exitFailed, nil
		}
		outf(c.err, "ox-say: lost contact with the daemon (%v); the voiceover keeps going. Check: ox-say produce status %s\n", err, s.ID)
		return exitFailed, nil
	}
	c.report(&final)
	return exitCode(final.Status), &final
}

// wait polls the project until it is no longer running. On a terminal the
// progress line rewrites itself (cut to the terminal's width, the rest of the
// line cleared); anywhere else (a log, a pipe) each change is its own line. A
// request that fails is retried pollRetries times in a row before giving up;
// a 404 ends at once (the project is gone).
func (c *produceCmd) wait(id string) (projectSummary, error) {
	tty := isTerminal(c.err)
	width := termWidth(c.err)
	last, failures := "", 0
	for {
		time.Sleep(c.poll)
		data, err := produceCall(http.MethodGet, producePath+"/"+url.PathEscape(id), nil)
		var ae *apiError
		if err != nil && (errors.As(err, &ae) || failures+1 >= pollRetries) {
			return projectSummary{}, err
		}
		if err != nil {
			failures++
			continue
		}
		failures = 0
		s, err := decodeSummary(data)
		if err != nil {
			return s, err
		}
		line := fitLine(progressLine(&s, id), width)
		if !s.active() {
			if tty && last != "" {
				outf(c.err, "\r%s\r", clearLine)
			}
			return s, nil
		}
		switch {
		case tty:
			outf(c.err, "\r%s%s", line, clearLine)
		case line != last:
			outln(c.err, line)
		}
		last = line
	}
}

// clearLine erases from the cursor to the end of the terminal line.
const clearLine = "\x1b[K"

// fitLine cuts line to width-1 characters so it never wraps.
func fitLine(line string, width int) string {
	r := []rune(line)
	if width > 1 && len(r) > width-1 {
		return string(r[:width-2]) + "…"
	}
	return line
}

// termWidth is the terminal's column count, or a default.
func termWidth(w io.Writer) int {
	if f, ok := w.(*os.File); ok {
		if ws, err := unix.IoctlGetWinsize(int(f.Fd()), unix.TIOCGWINSZ); err == nil && ws.Col > 0 {
			return int(ws.Col)
		}
	}
	return defaultTermWidth
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
	if s.active() {
		return exitDone // still going: nothing has gone wrong
	}
	return exitCode(s.Status)
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
	code, _ := c.follow(data)
	return code
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
