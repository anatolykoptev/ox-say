// Package testutil provides the fake tts-server child used by the test
// suite, plus small helpers. The fake child is the test binary re-exec'd with
// OXSAY_FAKE_CHILD=1 (the standard os/exec helper-process pattern).
//
// Behaviour knobs (env):
//
//	OXSAY_FAKE_CHILD=1        run the fake child instead of the test suite
//	OXSAY_FAKE_DIR            stamp dir: "spawn-<pid>" on start,
//	                          "speech-cancelled" when a speech request's ctx ends
//	OXSAY_FAKE_START_DELAY_MS /health answers 503 until this delay passes
//	OXSAY_FAKE_EXIT_MS        exit(1) after this many ms
//	OXSAY_FAKE_EXIT_ONCE      with EXIT_MS: only self-exit once per FAKE_DIR
//	OXSAY_FAKE_SPEECH_BLOCK   speech blocks until the request context ends
//	OXSAY_FAKE_IGNORE_SIGTERM SIGTERM is ignored; only SIGKILL ends the child
//
// Fake ox-stt (dispatched on OXSAY_FAKE_STT=1 AND a --engine flag in argv —
// the TTS fake never receives one, so both fakes can coexist in a test):
//
//	OXSAY_FAKE_STT=1          run the fake ox-stt
//	OXSAY_FAKE_STT_LOG        append-only record file; lines:
//	                          "argv\t<id>\t<arg>\t..." on spawn,
//	                          "start <id> <pid> <unixns>" and
//	                          "end <id> <pid> <unixns>" around the run —
//	                          <id> is the basename of the -f argument
//	OXSAY_FAKE_STT_DELAY_MS   sleep before answering (overlap window)
//	OXSAY_FAKE_STT_EXIT=1     print a message on stderr and exit 1
//	OXSAY_FAKE_STT_BLOCK=1    block until killed
//	OXSAY_FAKE_STT_JSON       payload to print instead of the canned result
//
// Fake ox-stt --serve (selected on OXSAY_FAKE_STT=1 AND a --serve flag in
// argv, checked BEFORE the --engine CLI selection above — the two fake
// modes never overlap): parses --port and serves on 127.0.0.1:
//
//	GET  /health      -> 200
//	POST /transcribe  -> OXSAY_FAKE_STT_JSON or the canned CLI result
//
// Streaming sessions (the ox-stt --serve contract): only when argv carries
// --vad, mirroring the real server — OXSAY_FAKE_STT_NO_VAD=1 forces 501
// either way, standing in for an ox-stt without session support:
//
//	POST   /sessions            -> 200 {"id":"<32 lowercase hex>"} (429 past 4)
//	POST   /sessions/{id}/audio -> 200 one segment "chunk <n>" per chunk, two
//	                               for a chunk of 3200 bytes or more (so one
//	                               response can carry several); logs
//	                               "sess-audio <id> <content-length> <content-type>"
//	POST   /sessions/{id}/finish -> 200 done with text = the chunks joined;
//	                               logs "sess-finish <id>"
//	DELETE /sessions/{id}        -> 200 {}; logs "sess-del <id>"
//
// As on the real server each segment is returned once: /audio and /finish
// answer only the segments not sent by an earlier response.
//
// The session routes mirror the server's own guard: the exact Content-Type
// per route (415 otherwise) and an exact Content-Length on POST (400 on a
// chunked/missing length). Unknown ids are 404.
//
// It appends to OXSAY_FAKE_STT_LOG:
//
//   - "serve\t<pid>\t<arg>\t..." on start (tab-separated argv);
//
//   - "req <pid> <content-type> <unixns>" per /transcribe request;
//
//   - "sess-audio <id> <bytes> <content-type>", "sess-finish <id>",
//     "sess-del <id>" per session request.
//
//     OXSAY_FAKE_STT_SERVE_STATUS   the HTTP status /transcribe answers
//     OXSAY_FAKE_STT_SERVE_DELAY_MS sleep before answering /transcribe
//     OXSAY_FAKE_STT_SERVE_EXIT=1   a serve child that cannot start: exit 1
//     right after logging its serve record (port taken, ox-stt without
//     --serve, a corrupt model)
//     OXSAY_FAKE_STT_NO_VAD=1       session routes answer 501 even when the
//     spawn argv carries --vad
package testutil

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// FakeChildMain runs the fake engine when the env marker is set, then exits.
// Call it first in every test package's TestMain.
func FakeChildMain() {
	// The STT fakes are selected by argv shape, not only by their env
	// marker: both markers are typically set in daemon tests. A --serve
	// argv runs the resident-server fake; a --engine argv the per-call CLI
	// fake (the TTS fake never sees either).
	if os.Getenv("OXSAY_FAKE_STT") == "1" {
		if sttServeArgv(os.Args[1:]) {
			os.Exit(runFakeSTTServe(os.Args[1:]))
		}
		if sttArgv(os.Args[1:]) {
			os.Exit(runFakeSTT(os.Args[1:]))
		}
	}
	if os.Getenv("OXSAY_FAKE_CHILD") != "1" {
		return
	}
	os.Exit(runFakeChild())
}

// fakeSTTSession is one live session in the fake `ox-stt --serve`: the
// chunk texts it has taken so far, joined verbatim by /finish, and how many
// of its segments were already returned — like the real server, /audio and
// /finish each answer only the segments not sent before.
type fakeSTTSession struct {
	texts    []string
	returned int
}

// fakeSTTSegment is one session segment as the real ox-stt emits it,
// including the segmenter cut diagnostics (cut/min_p/quiet_ms) the daemon
// logs. n is the segment's index: each field takes a DISTINCT value per
// segment, so a consumer that reports segment 0's values for every segment
// is caught.
func fakeSTTSegment(s, e float64, text string, n int) map[string]any {
	return map[string]any{
		"s": s, "e": e, "text": text,
		"cut":      []string{"pause", "cap", "finish"}[n%3],
		"min_p":    []float64{0.2, 0.25, 0.3, 0.35}[n%4],
		"quiet_ms": 400 + 40*n,
	}
}

// fakeSTTSegments drains the session's not-yet-returned segments — one per
// text at index >= s.returned — and marks them returned, as the real
// server's `returned` cursor does on both /audio and /finish. Called under
// sessMu.
func fakeSTTSegments(s *fakeSTTSession) []map[string]any {
	segs := make([]map[string]any, 0, len(s.texts)-s.returned)
	for i := s.returned; i < len(s.texts); i++ {
		segs = append(segs, fakeSTTSegment(float64(i), float64(i+1), s.texts[i], i))
	}
	s.returned = len(s.texts)
	return segs
}

// sttArgv reports whether argv looks like an ox-stt invocation.
func sttArgv(args []string) bool {
	for _, a := range args {
		if a == "--engine" {
			return true
		}
	}
	return false
}

// sttServeArgv reports whether argv looks like an `ox-stt --serve` one.
func sttServeArgv(args []string) bool {
	for _, a := range args {
		if a == "--serve" {
			return true
		}
	}
	return false
}

// sttResultJSON is the canned ox-stt result; OXSAY_FAKE_STT_JSON overrides
// it (shared by the CLI fake's stdout and the serve fake's /transcribe).
func sttResultJSON() string {
	if p := os.Getenv("OXSAY_FAKE_STT_JSON"); p != "" {
		return p
	}
	return `{"engine":"parakeet","language":"en","duration_s":0.05,"elapsed_s":0.01,` +
		`"text":"hello world.","segments":[{"s":0.0,"e":0.05,"text":"hello world."}],` +
		`"words":[{"w":"hello","s":0.0,"e":0.03,"p":0.99},{"w":"world.","s":0.03,"e":0.05,"p":0.98}]}`
}

// sttLog appends one record line to OXSAY_FAKE_STT_LOG.
func sttLog(rec string) {
	log := os.Getenv("OXSAY_FAKE_STT_LOG")
	if log == "" {
		return
	}
	f, err := os.OpenFile(log, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintln(f, rec)
	_ = f.Close()
}

// runFakeSTTServe is the fake resident ox-stt: it records its argv as a
// "serve" line, then serves /health and /transcribe on 127.0.0.1:<--port>,
// logging a "req" line per transcription request.
func runFakeSTTServe(args []string) int {
	var port int
	for i, a := range args {
		if a == "--port" && i+1 < len(args) {
			port, _ = strconv.Atoi(args[i+1])
		}
	}
	sttLog("serve\t" + strconv.Itoa(os.Getpid()) + "\t" + strings.Join(args, "\t"))

	if os.Getenv("OXSAY_FAKE_STT_SERVE_EXIT") == "1" {
		return 1
	}

	status := http.StatusOK
	if v, err := strconv.Atoi(os.Getenv("OXSAY_FAKE_STT_SERVE_STATUS")); err == nil && v != 0 {
		status = v
	}
	delay := envMS("OXSAY_FAKE_STT_SERVE_DELAY_MS")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("POST /transcribe", func(w http.ResponseWriter, r *http.Request) {
		sttLog(fmt.Sprintf("req %d %s %d", os.Getpid(), r.Header.Get("Content-Type"), time.Now().UnixNano()))
		if delay > 0 {
			select {
			case <-time.After(delay):
			case <-r.Context().Done():
				return
			}
		}
		if status != http.StatusOK {
			http.Error(w, "fake-stt: transcribe failed", status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintln(w, sttResultJSON())
	})

	// Streaming sessions exist only when the spawn argv carries --vad (the
	// real server's gate); OXSAY_FAKE_STT_NO_VAD forces the no-VAD answer.
	noVAD := os.Getenv("OXSAY_FAKE_STT_NO_VAD") == "1"
	if !noVAD {
		noVAD = true
		for _, a := range args {
			if a == "--vad" {
				noVAD = false
			}
		}
	}
	var sessMu sync.Mutex
	sessions := map[string]*fakeSTTSession{}

	sessErr := func(w http.ResponseWriter, code int, msg string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
	}
	// The real server's own guard on the session POSTs: the exact
	// Content-Type for the route and an exact Content-Length (no chunked).
	sessCheck := func(w http.ResponseWriter, r *http.Request, wantCT string) bool {
		if r.Header.Get("Content-Type") != wantCT {
			sessErr(w, http.StatusUnsupportedMediaType, "content type must be "+wantCT)
			return false
		}
		if len(r.TransferEncoding) != 0 || r.ContentLength < 0 {
			sessErr(w, http.StatusBadRequest, "an exact Content-Length is required")
			return false
		}
		return true
	}
	mux.HandleFunc("POST /sessions", func(w http.ResponseWriter, r *http.Request) {
		if noVAD {
			sessErr(w, http.StatusNotImplemented, "sessions need the VAD model (--vad)")
			return
		}
		if !sessCheck(w, r, "application/json") {
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		var rnd [16]byte
		if _, err := rand.Read(rnd[:]); err != nil {
			sessErr(w, http.StatusInternalServerError, "rand")
			return
		}
		sessMu.Lock()
		defer sessMu.Unlock()
		if len(sessions) >= 4 {
			sessErr(w, http.StatusTooManyRequests, "too many sessions")
			return
		}
		id := hex.EncodeToString(rnd[:])
		sessions[id] = &fakeSTTSession{}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"id": id})
	})
	mux.HandleFunc("POST /sessions/{id}/audio", func(w http.ResponseWriter, r *http.Request) {
		if noVAD {
			sessErr(w, http.StatusNotImplemented, "sessions need the VAD model (--vad)")
			return
		}
		if !sessCheck(w, r, "application/octet-stream") {
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		id := r.PathValue("id")
		sttLog(fmt.Sprintf("sess-audio %s %d %s", id, r.ContentLength, r.Header.Get("Content-Type")))
		sessMu.Lock()
		s, ok := sessions[id]
		var segs []map[string]any
		if ok {
			closed := 1
			if r.ContentLength >= 3200 {
				closed = 2
			}
			for range closed {
				s.texts = append(s.texts, "chunk "+strconv.Itoa(len(s.texts)+1))
			}
			segs = fakeSTTSegments(s)
		}
		sessMu.Unlock()
		if !ok {
			sessErr(w, http.StatusNotFound, "unknown session")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"segments": segs,
			"words":    []any{},
			"pending":  0,
		})
	})
	mux.HandleFunc("POST /sessions/{id}/finish", func(w http.ResponseWriter, r *http.Request) {
		if noVAD {
			sessErr(w, http.StatusNotImplemented, "sessions need the VAD model (--vad)")
			return
		}
		if !sessCheck(w, r, "application/json") {
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		id := r.PathValue("id")
		sttLog("sess-finish " + id)
		sessMu.Lock()
		s, ok := sessions[id]
		var segs []map[string]any
		if ok {
			segs = fakeSTTSegments(s)
			delete(sessions, id)
		}
		sessMu.Unlock()
		if !ok {
			sessErr(w, http.StatusNotFound, "unknown session")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"segments": segs, "words": []any{}, "pending": 0,
			"done": true, "text": strings.Join(s.texts, " "),
		})
	})
	mux.HandleFunc("DELETE /sessions/{id}", func(w http.ResponseWriter, r *http.Request) {
		if noVAD {
			sessErr(w, http.StatusNotImplemented, "sessions need the VAD model (--vad)")
			return
		}
		id := r.PathValue("id")
		sttLog("sess-del " + id)
		sessMu.Lock()
		_, ok := sessions[id]
		delete(sessions, id)
		sessMu.Unlock()
		if !ok {
			sessErr(w, http.StatusNotFound, "unknown session")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintln(w, "{}")
	})

	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		fmt.Fprintln(os.Stderr, "fake-stt serve: listen:", err)
		return 2
	}
	_ = http.Serve(ln, mux)
	return 0
}

// runFakeSTT is the fake ox-stt: records argv and start/end stamps, sleeps
// the configured delay, then prints canned JSON, exits 1, or blocks.
func runFakeSTT(args []string) int {
	var file string
	for i, a := range args {
		if (a == "-f" || a == "--file") && i+1 < len(args) {
			file = args[i+1]
		}
	}
	id := filepath.Base(file)
	stamp := sttLog
	stamp("argv\t" + id + "\t" + strings.Join(args, "\t"))
	stamp(fmt.Sprintf("start %s %d %d", id, os.Getpid(), time.Now().UnixNano()))
	// The closure is required: fmt.Sprintf's arguments (time.Now) would
	// otherwise be captured at defer registration, not at exit.
	defer func() {
		stamp(fmt.Sprintf("end %s %d %d", id, os.Getpid(), time.Now().UnixNano()))
	}()

	if os.Getenv("OXSAY_FAKE_STT_BLOCK") == "1" {
		for {
			time.Sleep(time.Hour)
		}
	}
	if d := envMS("OXSAY_FAKE_STT_DELAY_MS"); d > 0 {
		time.Sleep(d)
	}
	if os.Getenv("OXSAY_FAKE_STT_EXIT") == "1" {
		fmt.Fprintln(os.Stderr, "fake-stt: transcription failed")
		return 1
	}
	fmt.Println(sttResultJSON())
	return 0
}

func runFakeChild() int {
	fs := flag.NewFlagSet("fake-child", flag.ContinueOnError)
	port := fs.Int("port", 0, "")
	// Accepted and ignored, mirroring the real tts-server CLI.
	_ = fs.String("model", "", "")
	_ = fs.String("codec", "", "")
	_ = fs.String("host", "127.0.0.1", "")
	_ = fs.Int("max-batch", 1, "")
	if err := fs.Parse(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "fake-child:", err)
		return 2
	}
	dir := os.Getenv("OXSAY_FAKE_DIR")
	if dir != "" {
		_ = os.WriteFile(filepath.Join(dir, "spawn-"+strconv.Itoa(os.Getpid())), nil, 0o644)
	}
	if os.Getenv("OXSAY_FAKE_IGNORE_SIGTERM") == "1" {
		// A child that does not honour SIGTERM: killChild's escalation to
		// SIGKILL after KillGrace is the only way down.
		signal.Notify(make(chan os.Signal, 1), syscall.SIGTERM)
	}
	delay := envMS("OXSAY_FAKE_START_DELAY_MS")
	started := time.Now()

	var mu sync.Mutex
	registry := map[string]string{} // name → ref_text

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		if time.Since(started) < delay {
			http.Error(w, "loading", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /v1/audio/voices", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		list := make([]map[string]string, 0, len(registry))
		for n, rt := range registry {
			list = append(list, map[string]string{"name": n, "ref_text": rt})
		}
		mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"voices": list})
	})
	mux.HandleFunc("POST /v1/audio/voices", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Name    string `json:"name"`
			WavB64  string `json:"wav_b64"`
			RefText string `json:"ref_text"`
		}
		// Mirror the real engine: the clip payload is mandatory and must
		// decode — a client that forgets or garbles it gets a 400.
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" {
			http.Error(w, "bad voice", http.StatusBadRequest)
			return
		}
		if body.WavB64 == "" {
			http.Error(w, "wav_b64 is required", http.StatusBadRequest)
			return
		}
		if _, err := base64.StdEncoding.DecodeString(body.WavB64); err != nil {
			http.Error(w, "wav_b64 is not base64", http.StatusBadRequest)
			return
		}
		mu.Lock()
		registry[body.Name] = body.RefText
		mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"name": body.Name, "status": "registered"})
	})
	mux.HandleFunc("DELETE /v1/audio/voices/{name}", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if _, ok := registry[r.PathValue("name")]; !ok {
			http.Error(w, "no such voice", http.StatusNotFound)
			return
		}
		delete(registry, r.PathValue("name"))
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("POST /v1/audio/speech", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if dir != "" {
			raw, _ := json.Marshal(body)
			_ = os.WriteFile(filepath.Join(dir, "speech-last.json"), raw, 0o644)
		}
		voice, _ := body["voice"].(string)
		if voice != "" {
			mu.Lock()
			_, ok := registry[voice]
			mu.Unlock()
			if !ok {
				http.Error(w, "unknown voice", http.StatusBadRequest)
				return
			}
		}
		if os.Getenv("OXSAY_FAKE_SPEECH_BLOCK") == "1" {
			if dir != "" {
				_ = os.WriteFile(filepath.Join(dir, "speech-started"), nil, 0o644)
			}
			<-r.Context().Done()
			if dir != "" {
				_ = os.WriteFile(filepath.Join(dir, "speech-cancelled"), nil, 0o644)
			}
			return
		}
		w.Header().Set("Content-Type", "audio/wav")
		_, _ = w.Write(TinyWAV())
	})

	if exitMS := envMS("OXSAY_FAKE_EXIT_MS"); exitMS > 0 {
		go func() {
			time.Sleep(exitMS)
			if os.Getenv("OXSAY_FAKE_EXIT_ONCE") == "1" && dir != "" {
				// O_EXCL create is atomic — overlapping fake-child
				// generations cannot both pass a stat-then-write check.
				f, err := os.OpenFile(filepath.Join(dir, "already-exited"),
					os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
				if err != nil {
					return
				}
				_ = f.Close()
			}
			os.Exit(1)
		}()
	}

	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(*port))
	if err != nil {
		fmt.Fprintln(os.Stderr, "fake-child: listen:", err)
		return 2
	}
	_ = http.Serve(ln, mux)
	return 0
}

func envMS(key string) time.Duration {
	v, _ := strconv.Atoi(os.Getenv(key))
	return time.Duration(v) * time.Millisecond
}

// FreePort returns a free loopback TCP port.
func FreePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

// WaitFor polls cond every 10 ms until it holds or the timeout expires.
func WaitFor(t *testing.T, timeout time.Duration, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// SpawnStamps counts spawn-<pid> stamp files the fake children left in dir.
func SpawnStamps(t *testing.T, dir string) int {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(dir, "spawn-*"))
	if err != nil {
		t.Fatal(err)
	}
	return len(matches)
}

// TinyWAV returns a minimal valid 24 kHz mono s16le WAV (~50 ms).
func TinyWAV() []byte {
	const rate = 24000
	samples := rate / 20
	data := make([]byte, 44+samples*2)
	copy(data, "RIFF")
	putU32(data[4:], uint32(36+samples*2))
	copy(data[8:], "WAVE")
	copy(data[12:], "fmt ")
	putU32(data[16:], 16)
	putU16(data[20:], 1) // PCM
	putU16(data[22:], 1) // mono
	putU32(data[24:], rate)
	putU32(data[28:], rate*2)
	putU16(data[32:], 2) // block align
	putU16(data[34:], 16)
	copy(data[36:], "data")
	putU32(data[40:], uint32(samples*2))
	return data
}

// WriteTinyWAV writes TinyWAV to dir/voice.wav and returns the path.
func WriteTinyWAV(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, TinyWAV(), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func putU16(b []byte, v uint16) { b[0], b[1] = byte(v), byte(v>>8) }
func putU32(b []byte, v uint32) {
	b[0], b[1], b[2], b[3] = byte(v), byte(v>>8), byte(v>>16), byte(v>>24)
}
