package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

func seedStoredVoice(t *testing.T, d *Daemon, name string, secs float64, refText string) {
	t.Helper()
	wav := d.Store.WAVPath(name)
	if err := os.WriteFile(wav, testutil.SilentWAV(secs), 0o644); err != nil {
		t.Fatal(err)
	}
	meta, _ := json.Marshal(map[string]any{"name": name, "ref_text": refText, "created": "2026-10-04T14:28:00Z"})
	if err := os.WriteFile(strings.TrimSuffix(wav, ".wav")+".json", meta, 0o644); err != nil {
		t.Fatal(err)
	}
}

func fakeWords(n int) []voices.Word {
	out := make([]voices.Word, n)
	for i := range out {
		s := float64(i) * 0.4
		w := "w" + string(rune('a'+i%26))
		if i%6 == 5 {
			w += "." // a sentence end every 6 words, as real speech has
		}
		out[i] = voices.Word{W: w, S: s, E: s + 0.3}
	}
	return out
}

// A daemon start repairs a stored voice whose transcript runs past its
// audio: the stored pair is rewritten, the original kept, and the live child
// re-registered with the new text. A second pass does not transcribe again.
// Mutation: internal/daemon/voicerepair.go repairVoice — delete the
// PrepareRepair call's diagnosis (return before r.Apply()) -> RED.
func TestRepairVoicesRewritesAndReregisters(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	long := strings.TrimSpace(strings.Repeat("word ", 90))
	seedStoredVoice(t, d, "snakes", 20, long)
	seedStoredVoice(t, d, "native", 5.4, "one two three four five six seven eight nine ten eleven")
	calls := 0
	d.Store.SetTranscriber(func(context.Context, string) ([]voices.Word, error) {
		calls++
		return fakeWords(60), nil
	})

	g := d.Sup.Acquire()
	defer g.Release()
	base, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	d.RepairVoices(context.Background())

	v, err := d.Store.Get("snakes")
	if err != nil || v.RefText == long || !strings.HasPrefix(v.RefText, "wa wb") {
		t.Fatalf("snakes = %+v, %v; want the transcript as ref_text", v, err)
	}
	if got := childVoices(t, base)["snakes"]; got != v.RefText {
		t.Fatalf("live child holds ref_text %q, want the repaired %q", got, v.RefText)
	}
	if _, err := os.Stat(strings.TrimSuffix(d.Store.WAVPath("snakes"), ".wav") + ".orig.wav"); err != nil {
		t.Fatalf("backup wav missing: %v", err)
	}
	if n, _ := d.Store.Get("native"); n.RefText != "one two three four five six seven eight nine ten eleven" {
		t.Fatalf("healthy voice modified: %q", n.RefText)
	}
	if !testLogSaw(t, "voice repaired") {
		t.Fatal("no log line for the repaired voice")
	}
	if calls != 1 {
		t.Fatalf("transcriber calls = %d, want 1 (healthy voice must not be transcribed)", calls)
	}
	d.RepairVoices(context.Background())
	if calls != 1 {
		t.Fatalf("second pass re-transcribed: calls = %d", calls)
	}
}

// With STT unavailable the broken voice is kept as is and a warning is logged.
func TestRepairVoicesSTTUnavailableWarns(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil) // Cfg has no STT model: the default transcriber fails
	long := strings.TrimSpace(strings.Repeat("word ", 90))
	seedStoredVoice(t, d, "snakes", 20, long)
	d.RepairVoices(context.Background())
	if v, _ := d.Store.Get("snakes"); v.RefText != long {
		t.Fatalf("voice modified despite failing STT: %q", v.RefText)
	}
	if !testLogSaw(t, "speech-to-text unavailable") {
		t.Fatal("no warning logged for the unrepairable voice")
	}
}

// The voice-add response gains "notice" only when a ref_text was replaced;
// otherwise it is byte-for-byte the old three-key object.
func TestAddVoiceNoticeInResponse(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	d.Store.SetTranscriber(func(context.Context, string) ([]voices.Word, error) {
		return fakeWords(60), nil
	})
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	post := func(name string, secs float64) map[string]any {
		src := testutil.WriteSilentWAV(t, dir, name+".wav", secs)
		body, _ := json.Marshal(map[string]any{"name": name, "audio_path": src, "ref_text": "typed by hand"})
		resp, err := http.Post(srv.URL+"/v1/audio/voices", "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s: %s: %s", name, resp.Status, raw)
		}
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	if m := post("short", 8); len(m) != 3 {
		t.Fatalf("short clip response = %v, want exactly name/status/registered_to_engine", m)
	}
	m := post("long", 30)
	if n, _ := m["notice"].(string); !strings.Contains(n, "replaced ref_text") {
		t.Fatalf("long clip response = %v, want a notice", m)
	}
	if v, _ := d.Store.Get("long"); v.RefText == "typed by hand" {
		t.Fatal("ref_text not replaced")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(d.Store.WAVPath("long")), "long.orig.json")); err == nil {
		t.Fatal("a fresh add must not create a backup")
	}
}

// fakeSTTPayload is an ox-stt result whose words are n speech words of 0.3 s
// every 0.4 s, a sentence end every sixth.
func fakeSTTPayload(t *testing.T, n int) string {
	t.Helper()
	type w struct {
		W string  `json:"w"`
		S float64 `json:"s"`
		E float64 `json:"e"`
		P float64 `json:"p"`
	}
	words := make([]w, n)
	for i := range words {
		tok := "tok" + string(rune('a'+i%26))
		if i%6 == 5 {
			tok += "."
		}
		s := float64(i) * 0.4
		words[i] = w{tok, s, s + 0.3, 0.9}
	}
	raw, err := json.Marshal(map[string]any{
		"engine": "parakeet", "duration_s": float64(n) * 0.4, "elapsed_s": 0.1,
		"text": "x", "segments": []any{}, "words": words,
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// voiceWords is the seam between the STT result and the voice store: start and
// end must not be swapped, nor the text.
// Mutation: internal/daemon/voicerepair.go voiceWords — build
// voices.Word{W: w.W, S: w.E, E: w.S} -> RED.
func TestVoiceWordsMapsTimestamps(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	t.Setenv("OXSAY_FAKE_STT_JSON", `{"engine":"parakeet","duration_s":4,"elapsed_s":0.1,"text":"alpha beta.",`+
		`"segments":[],"words":[{"w":"alpha","s":1.25,"e":2.5,"p":0.9},{"w":"beta.","s":2.75,"e":4.0,"p":0.9}]}`)
	wav := testutil.WriteTinyWAV(t, dir, "in.wav")
	got, err := d.voiceWords(context.Background(), wav)
	if err != nil {
		t.Fatal(err)
	}
	want := []voices.Word{{W: "alpha", S: 1.25, E: 2.5}, {W: "beta.", S: 2.75, E: 4.0}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("voiceWords = %+v, want %+v", got, want)
	}
}

// A real daemon wires its own STT into the voice store: a too-long clip is
// cut and re-transcribed without any test-injected transcriber.
// Mutation: internal/daemon/service.go newDaemon — delete
// `store.SetTranscriber(d.voiceWords)` -> RED (the add is refused as
// "speech-to-text is unavailable").
func TestDaemonWiresSTTIntoVoiceStore(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	t.Setenv("OXSAY_FAKE_STT_JSON", fakeSTTPayload(t, 60)) // 24 s of speech
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 30)
	v, _, err := d.AddVoice(context.Background(), "ben", src, "typed by hand, much too long for twenty seconds")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(v.RefText, "toka tokb") || strings.Contains(v.RefText, "typed") {
		t.Fatalf("ref_text = %q, want the fake STT's words", v.RefText)
	}
	if v.Notice == "" {
		t.Fatal("no notice")
	}
}

// The repair pass waits for the HTTP listener: a daemon whose bind fails must
// exit without having touched a voice. StopVoiceRepair ends a waiting pass.
// Mutation: internal/daemon/voicerepair.go StartVoiceRepair — drop the
// waitListening gate (call RepairVoices directly) -> RED.
func TestStartVoiceRepairWaitsForListener(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close() // nobody listens on addr now
	d.Cfg.Addr = addr
	long := strings.TrimSpace(strings.Repeat("word ", 90))
	seedStoredVoice(t, d, "snakes", 20, long)
	d.Store.SetTranscriber(func(context.Context, string) ([]voices.Word, error) { return fakeWords(60), nil })

	d.StartVoiceRepair()
	time.Sleep(500 * time.Millisecond)
	if v, _ := d.Store.Get("snakes"); v.RefText != long {
		t.Fatal("repair ran before the listener was up")
	}
	ln2, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer ln2.Close()
	testutil.WaitFor(t, 10*time.Second, func() bool {
		v, _ := d.Store.Get("snakes")
		return v != nil && v.RefText != long
	}, "repair after the listener came up")
	d.StopVoiceRepair() // returns: the pass is done
}
