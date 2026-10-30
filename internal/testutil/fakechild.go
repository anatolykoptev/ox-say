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
//	OXSAY_FAKE_SPEECH_DROP=1  speech closes the connection without answering
//	OXSAY_FAKE_IGNORE_SIGTERM SIGTERM is ignored; only SIGKILL ends the child
//	                          (the voxcpm2 fake too)
//	OXSAY_FAKE_SPEECH_LOG     append-only file: one JSON line per speech body
//	OXSAY_FAKE_SPEECH_RUNAWAY n | n+ | all: the n-th speech request (1-based,
//	                          counted per child), every one from the n-th on
//	                          ("n+"), or every one ("all") answers like the real engine whose talker
//	                          never emitted EOS and hit its frame budget:
//	                          502 + error type "generation_runaway"
//	OXSAY_FAKE_SPEECH_ABORT   n: the n-th speech request starts a 200 stream
//	                          and cuts the connection mid-body (the engine's
//	                          answer to a failure after the stream began)
//
// Fake audiocpp_server (the voxcpm2 child; selected on OXSAY_FAKE_VOX=1 AND a
// --config flag in argv, checked first): reads host/port from the --config
// JSON and serves on them:
//
//	OXSAY_FAKE_VOX=1          run the fake audiocpp_server
//	OXSAY_FAKE_VOX_LOG        append-only file: one line per POST
//	                          /v1/audio/speech body
//	OXSAY_FAKE_VOX_SECS       seconds of silence the speech route answers
//	                          (default 1; a long value stands in for a
//	                          runaway take)
//	OXSAY_FAKE_VOX_DROP=1     close the connection on a speech request
//	                          without answering (a transport failure)
//	OXSAY_FAKE_VOX_FAIL=1     answer HTTP 500 with a message that names the
//	                          request's voice_ref path (the real engine does
//	                          when it cannot open the recording)
//	OXSAY_FAKE_VOX_HANG_ONCE  path: the first speech request that finds no such
//	                          file creates it and never answers (a wedged
//	                          child); every later request, on any child,
//	                          answers normally
//	OXSAY_FAKE_VOX_DELAY_MS   sleep before answering a speech request
//	OXSAY_FAKE_VOX_STALL_BODY=1 send the 200 header, flush it, then no body
//	                          until the client goes away
//	OXSAY_FAKE_VOX_WEDGE_FIRST path: the first child to get a speech request and
//	                          create this file is wedged for good - it
//	                          accepts every request from then on and answers
//	                          none (a hung single-threaded engine, so later
//	                          requests queue behind the first); children that
//	                          find the file already there answer normally
//
// OXSAY_FAKE_TONE=1 makes both fakes answer a quiet sine instead of silence
// or a click — audio a loudness meter can measure — at their engine's native
// rate (48 kHz voxcpm2, 24 kHz qwen).
//
// With OXSAY_FAKE_DIR set it stamps "vox-spawn-<pid>" holding the argv, one
// argument per line.
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
//	OXSAY_FAKE_STT_KILL=1     SIGKILL itself with nothing on stderr (an engine killed from outside)
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
//
// Fake ox-llm (llama-server, the notes engine; selected on
// OXSAY_FAKE_LLM=1): parses --port and --api-key-file, stamps
// "llm-spawn-<pid>" under OXSAY_FAKE_DIR holding the full argv (one
// argument per line, argv[0] first) and "llm-metal-<pid>" holding the child's GGML_METAL_CONCURRENCY_DISABLE
// ("unset" when absent), then serves on 127.0.0.1:
//
//	GET  /health                -> 503 while OXSAY_FAKE_START_DELAY_MS has
//	                               not passed (a model still loading), then 200
//	GET  /v1/models             -> 401 when the Authorization bearer differs
//	                               from the key file's content, else 200
//	POST /v1/chat/completions   -> 503 in the load window, 401 when the
//	                               Authorization bearer differs from the key
//	                               file's content, else a canned reply
//
// Like llama-server, it exits at once when --api-key-file names a file it
// cannot read, and runs without auth when the file holds no key.
//
//	OXSAY_FAKE_LLM=1            run the fake ox-llm
//	OXSAY_FAKE_LLM_EXIT=1       exit 1 at once (the engine cannot load)
//	OXSAY_FAKE_LLM_OPEN=1       ignore the key: every route answers without
//	                            auth, as llama-server does with an empty key
//	                            file (zero keys = no auth, CORS "*")
//	OXSAY_FAKE_LLM_LOADING_SPAWNS=n  the first n spawns (counted by the stamps
//	                            in OXSAY_FAKE_DIR) never become healthy
//	OXSAY_FAKE_LLM_JSON         the message content /v1/chat/completions
//	                            returns (default "the canned notes")
package testutil

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
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
	if os.Getenv("OXSAY_FAKE_LLM") == "1" {
		os.Exit(runFakeLLM(os.Args[1:]))
	}
	if os.Getenv("OXSAY_FAKE_VOX") == "1" && hasFlagArg(os.Args[1:], "--config") {
		os.Exit(runFakeVox(os.Args[1:]))
	}
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

// runFakeLLM is the fake ox-llm: a stand-in for llama-server as the notes
// engine runs it. It stamps its argv for the caller to inspect, answers
// /health like a model server that is still loading, and requires the
// bearer key the spawn argv's --api-key-file names.
func runFakeLLM(args []string) int {
	var port int
	var keyFile string
	for i, a := range args {
		switch {
		case a == "--port" && i+1 < len(args):
			port, _ = strconv.Atoi(args[i+1])
		case a == "--api-key-file" && i+1 < len(args):
			keyFile = args[i+1]
		}
	}
	loadingSpawns, _ := strconv.Atoi(os.Getenv("OXSAY_FAKE_LLM_LOADING_SPAWNS"))
	spawnIndex := 0
	if dir := os.Getenv("OXSAY_FAKE_DIR"); dir != "" {
		prior, _ := filepath.Glob(filepath.Join(dir, "llm-spawn-*"))
		spawnIndex = len(prior)
		_ = os.WriteFile(filepath.Join(dir, "llm-spawn-"+strconv.Itoa(os.Getpid())), []byte(strings.Join(os.Args, "\n")), 0o644)
		// The one variable the notes engine's spawn sets on a discrete card (#238): "unset" when it is not in the env.
		metal, set := os.LookupEnv("GGML_METAL_CONCURRENCY_DISABLE")
		if !set {
			metal = "unset"
		}
		_ = os.WriteFile(filepath.Join(dir, "llm-metal-"+strconv.Itoa(os.Getpid())), []byte(metal), 0o644)
	}
	if os.Getenv("OXSAY_FAKE_LLM_EXIT") == "1" {
		fmt.Fprintln(os.Stderr, "fake-llm: cannot load the model")
		return 1
	}
	delay := envMS("OXSAY_FAKE_START_DELAY_MS")
	if spawnIndex < loadingSpawns {
		delay = time.Hour // still loading when the supervisor's health wait ends
	}
	started := time.Now()
	loading := func() bool { return time.Since(started) < delay }
	reply := os.Getenv("OXSAY_FAKE_LLM_JSON")
	if reply == "" {
		reply = "the canned notes"
	}
	open := os.Getenv("OXSAY_FAKE_LLM_OPEN") == "1"
	if keyFile != "" {
		want, err := os.ReadFile(keyFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "fake-llm: cannot read the api key file:", err)
			return 1
		}
		open = open || strings.TrimSpace(string(want)) == ""
	}
	open = open || keyFile == ""
	authed := func(r *http.Request) bool {
		if open {
			return true
		}
		want, _ := os.ReadFile(keyFile)
		return r.Header.Get("Authorization") == "Bearer "+strings.TrimSpace(string(want))
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		if loading() {
			http.Error(w, "loading", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, r *http.Request) {
		if !authed(r) {
			http.Error(w, "bad key", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[{"id":"notes"}]}`))
	})
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		if loading() {
			http.Error(w, "loading", http.StatusServiceUnavailable)
			return
		}
		if !authed(r) {
			http.Error(w, "bad key", http.StatusUnauthorized)
			return
		}
		raw, _ := json.Marshal(map[string]any{
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": reply},
				"finish_reason": "stop",
			}},
		})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw)
	})
	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		fmt.Fprintln(os.Stderr, "fake-llm: listen:", err)
		return 2
	}
	_ = http.Serve(ln, mux)
	return 0
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
	if os.Getenv("OXSAY_FAKE_STT_KILL") == "1" {
		_ = syscall.Kill(os.Getpid(), syscall.SIGKILL)
		select {} // the signal is not synchronous
	}
	fmt.Println(sttResultJSON())
	return 0
}

// runawayAt reports whether the nth speech request is one the knob
// OXSAY_FAKE_SPEECH_RUNAWAY ("n", "n+" or "all") makes run away.
func runawayAt(spec string, nth int) bool {
	if spec == "all" {
		return true
	}
	from := strings.HasSuffix(spec, "+")
	n, err := strconv.Atoi(strings.TrimSuffix(spec, "+"))
	if err != nil || n < 1 {
		return false
	}
	return nth == n || (from && nth > n)
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
	speechN := 0                    // speech requests served (guarded by mu)

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
		if logPath := os.Getenv("OXSAY_FAKE_SPEECH_LOG"); logPath != "" {
			raw, _ := json.Marshal(body)
			if f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
				_, _ = f.Write(append(raw, '\n'))
				_ = f.Close()
			}
		}
		mu.Lock()
		speechN++
		nth := speechN
		mu.Unlock()
		if runawayAt(os.Getenv("OXSAY_FAKE_SPEECH_RUNAWAY"), nth) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{
				"type":    "generation_runaway",
				"message": "generation ran past its frame budget without ending",
			}})
			return
		}
		if n, _ := strconv.Atoi(os.Getenv("OXSAY_FAKE_SPEECH_ABORT")); n > 0 && nth == n {
			w.Header().Set("Content-Type", "audio/pcm")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(make([]byte, 4800))
			w.(http.Flusher).Flush()
			if hj, ok := w.(http.Hijacker); ok {
				if c, _, err := hj.Hijack(); err == nil {
					_ = c.Close()
				}
			}
			return
		}
		if os.Getenv("OXSAY_FAKE_SPEECH_DROP") == "1" {
			if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
				_ = conn.Close()
			}
			return
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
		if os.Getenv(envFakeTone) == "1" {
			_, _ = w.Write(ToneWAV(QwenRate, ToneSecs, ToneAmp))
			return
		}
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

// FreePorts returns n pairwise distinct free loopback TCP ports. All n
// listeners stay open until every port is chosen, so the kernel cannot hand
// the same port out twice (calling FreePort n times can, because each call
// closes its listener before returning). Use it whenever one test needs more
// than one port.
//
// Residual window: the listeners are closed before FreePorts returns, so
// another process can still grab a port before the caller binds it. That is
// the same race a single FreePort call has.
func FreePorts(t *testing.T, n int) []int {
	t.Helper()
	ports := make([]int, 0, n)
	lns := make([]net.Listener, 0, n)
	defer func() {
		for _, ln := range lns {
			_ = ln.Close()
		}
	}()
	for i := 0; i < n; i++ {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		lns = append(lns, ln)
		ports = append(ports, ln.Addr().(*net.TCPAddr).Port)
	}
	return ports
}

// FreePort returns a free loopback TCP port. It closes the listener before
// returning, so another process can take the port before the caller binds
// it, and two calls may return the same port: a test that needs several
// ports must use FreePorts.
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

// SilentWAV is secs seconds of 24 kHz mono s16 silence — a stand-in reference
// clip of a chosen length.
func SilentWAV(secs float64) []byte {
	const rate = 24000
	samples := int(secs * rate)
	data := make([]byte, 44+samples*2)
	copy(data, "RIFF")
	putU32(data[4:], uint32(36+samples*2))
	copy(data[8:], "WAVE")
	copy(data[12:], "fmt ")
	putU32(data[16:], 16)
	putU16(data[20:], 1)
	putU16(data[22:], 1)
	putU32(data[24:], rate)
	putU32(data[28:], rate*2)
	putU16(data[32:], 2)
	putU16(data[34:], 16)
	copy(data[36:], "data")
	putU32(data[40:], uint32(samples*2))
	return data
}

// The fakes' tone take (OXSAY_FAKE_TONE=1) and the engines' native rates.
const (
	envFakeTone = "OXSAY_FAKE_TONE"
	QwenRate    = 24000
	VoxRate     = 48000
	ToneSecs    = 6.0  // long enough for an EBU R128 integrated reading
	ToneAmp     = 0.03 // linear amplitude of the sine: about -34 LUFS
	toneHz      = 440.0
)

// ToneWAV is secs seconds of a toneHz sine at linear amplitude amp, as mono
// s16le at rate.
func ToneWAV(rate int, secs, amp float64) []byte {
	samples := int(secs * float64(rate))
	data := make([]byte, 44+samples*2)
	copy(data, "RIFF")
	putU32(data[4:], uint32(36+samples*2))
	copy(data[8:], "WAVE")
	copy(data[12:], "fmt ")
	putU32(data[16:], 16)
	putU16(data[20:], 1)
	putU16(data[22:], 1)
	putU32(data[24:], uint32(rate))
	putU32(data[28:], uint32(rate*2))
	putU16(data[32:], 2)
	putU16(data[34:], 16)
	copy(data[36:], "data")
	putU32(data[40:], uint32(samples*2))
	for i := 0; i < samples; i++ {
		v := int16(amp * math.MaxInt16 * math.Sin(2*math.Pi*toneHz*float64(i)/float64(rate)))
		putU16(data[44+2*i:], uint16(v))
	}
	return data
}

// WriteSilentWAV writes SilentWAV(secs) to dir/name and returns the path.
func WriteSilentWAV(t *testing.T, dir, name string, secs float64) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, SilentWAV(secs), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
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

func hasFlagArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

// runFakeVox is the fake audiocpp_server: it reads host/port from the
// --config JSON, serves GET /health and POST /v1/audio/speech, appends each
// speech body as one JSON line to OXSAY_FAKE_VOX_LOG, and answers a silent WAV
// of OXSAY_FAKE_VOX_SECS seconds (default 1).
func runFakeVox(args []string) int {
	if os.Getenv("OXSAY_FAKE_IGNORE_SIGTERM") == "1" {
		signal.Notify(make(chan os.Signal, 1), syscall.SIGTERM) // only SIGKILL ends it
	}
	var path string
	for i, a := range args {
		if a == "--config" && i+1 < len(args) {
			path = args[i+1]
		}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fake-vox:", err)
		return 2
	}
	var sc struct {
		Host string `json:"host"`
		Port int    `json:"port"`
	}
	if err := json.Unmarshal(raw, &sc); err != nil {
		fmt.Fprintln(os.Stderr, "fake-vox:", err)
		return 2
	}
	if dir := os.Getenv("OXSAY_FAKE_DIR"); dir != "" {
		stamp := filepath.Join(dir, "vox-spawn-"+strconv.Itoa(os.Getpid()))
		_ = os.WriteFile(stamp, []byte(strings.Join(args, "\n")), 0o644)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	var mu sync.Mutex
	wedged, wedgeChecked := false, false
	mux.HandleFunc("POST /v1/audio/speech", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if !json.Valid(body) {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		if log := os.Getenv("OXSAY_FAKE_VOX_LOG"); log != "" {
			mu.Lock()
			f, err := os.OpenFile(log, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
			if err == nil {
				_, _ = f.Write(append(body, '\n'))
				_ = f.Close()
			}
			mu.Unlock()
		}
		if first := os.Getenv("OXSAY_FAKE_VOX_WEDGE_FIRST"); first != "" {
			mu.Lock()
			if !wedgeChecked {
				wedgeChecked = true
				if f, err := os.OpenFile(first, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644); err == nil {
					_ = f.Close()
					wedged = true
				}
			}
			isWedged := wedged
			mu.Unlock()
			if isWedged {
				<-r.Context().Done()
				return
			}
		}
		if once := os.Getenv("OXSAY_FAKE_VOX_HANG_ONCE"); once != "" {
			if f, err := os.OpenFile(once, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644); err == nil {
				_ = f.Close()
				<-r.Context().Done()
				return
			}
		}
		if ms, err := strconv.Atoi(os.Getenv("OXSAY_FAKE_VOX_DELAY_MS")); err == nil && ms > 0 {
			time.Sleep(time.Duration(ms) * time.Millisecond)
		}
		if os.Getenv("OXSAY_FAKE_VOX_FAIL") == "1" {
			var req struct {
				VoiceRef struct {
					Path string `json:"path"`
				} `json:"voice_ref"`
			}
			_ = json.Unmarshal(body, &req)
			http.Error(w, "cannot open reference audio "+req.VoiceRef.Path+": decode failed", http.StatusInternalServerError)
			return
		}
		if os.Getenv("OXSAY_FAKE_VOX_DROP") == "1" {
			if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
				_ = conn.Close()
			}
			return
		}
		if os.Getenv("OXSAY_FAKE_VOX_STALL_BODY") == "1" {
			w.Header().Set("Content-Type", "audio/wav")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		secs := 1.0
		if s, err := strconv.ParseFloat(os.Getenv("OXSAY_FAKE_VOX_SECS"), 64); err == nil {
			secs = s
		}
		w.Header().Set("Content-Type", "audio/wav")
		if os.Getenv(envFakeTone) == "1" {
			_, _ = w.Write(ToneWAV(VoxRate, ToneSecs, ToneAmp))
			return
		}
		_, _ = w.Write(SilentWAV(secs))
	})
	srv := &http.Server{Addr: fmt.Sprintf("%s:%d", sc.Host, sc.Port), Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, "fake-vox:", err)
		return 1
	}
	return 0
}
