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
package testutil

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"
)

// FakeChildMain runs the fake engine when the env marker is set, then exits.
// Call it first in every test package's TestMain.
func FakeChildMain() {
	if os.Getenv("OXSAY_FAKE_CHILD") != "1" {
		return
	}
	os.Exit(runFakeChild())
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
		var body struct {
			Input string `json:"input"`
			Voice string `json:"voice"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if body.Voice != "" {
			mu.Lock()
			_, ok := registry[body.Voice]
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
