package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
)

// lastSpeechInput is the "input" of the body the fake qwen child recorded
// last (OXSAY_FAKE_DIR/speech-last.json): the text the engine was asked to
// say, not the text the caller sent.
func lastSpeechInput(t *testing.T, dir string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "speech-last.json"))
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(data, &body); err != nil {
		t.Fatal(err)
	}
	in, _ := body["input"].(string)
	return in
}

// Plain speech hands the engine the same spoken text long-form produce
// renders — vscript.Spoken — on a Russian request: numbers and times become
// words while a URL, a version or a phone keeps its digits, and any other
// language's text reaches the engine byte-identical. The language is the
// daemon's own resolution: a recognized language field wins, else the
// input's script decides.
// Mutations: drop the normalizeSpeakText call in handleSpeech (http.go) ->
// every route case is RED; drop it in Speak (speak.go) -> the MCP test below
// is RED; remove the `langHint(body) != "ru"` gate -> the English cases go
// RED (a time expands with no Russian noun needed).
func TestSpeechExpandsRussianNumbers(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	for name, tc := range map[string]struct{ body, want string }{
		"russian numbers and time": {
			`{"input":"Мне 25 лет, приходи в 14:30"}`,
			"Мне двадцать пять лет, приходи в четырнадцать тридцать",
		},
		"mixed keeps machine digits": {
			`{"input":"Смотри https://ox.say/a1, версию 3.14, в 14:30"}`,
			"Смотри https://ox.say/a1, версию 3.14, в четырнадцать тридцать",
		},
		"english untouched": {
			`{"input":"I am 25"}`,
			"I am 25",
		},
		"english time untouched": {
			`{"input":"the meeting is at 14:30"}`,
			"the meeting is at 14:30",
		},
		"explicit english wins over cyrillic": {
			`{"input":"Мне 25 лет","language":"en"}`,
			"Мне 25 лет",
		},
		"explicit russian wins over latin": {
			`{"input":"call me at 14:30","language":"Russian"}`,
			"call me at четырнадцать тридцать",
		},
	} {
		rec := postSpeech(d, tc.body)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", name, rec.Code, bodyText(rec))
		}
		if got := lastSpeechInput(t, dir); got != tc.want {
			t.Errorf("%s: engine got %q, want %q", name, got, tc.want)
		}
	}
}

// The MCP speak tool shares Speak with the CLI: its engine request carries
// the same spoken text the HTTP route sends.
func TestSpeakToolExpandsRussianNumbers(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	cs := mcpSession(t, d)

	callMCP(t, cs, "speak", map[string]any{"text": "Мне 25 лет, приходи в 14:30"})
	if got, want := lastSpeechInput(t, dir), "Мне двадцать пять лет, приходи в четырнадцать тридцать"; got != want {
		t.Fatalf("MCP speak: engine got %q, want %q", got, want)
	}
}

// OX_SAY_LANG is the daemon's language default inside the same resolution:
// with it set to Russian an unmarked request is normalized whatever the
// script; an explicit language field still wins.
func TestSpeechLangDefaultFeedsNormalizer(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.Lang = "Russian" }, nil, nil)

	rec := postSpeech(d, `{"input":"call me at 14:30"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, bodyText(rec))
	}
	if got, want := lastSpeechInput(t, dir), "call me at четырнадцать тридцать"; got != want {
		t.Fatalf("OX_SAY_LANG=Russian: engine got %q, want %q", got, want)
	}

	rec = postSpeech(d, `{"input":"приходи в 14:30","language":"English"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, bodyText(rec))
	}
	if got, want := lastSpeechInput(t, dir), "приходи в 14:30"; got != want {
		t.Fatalf("explicit English under OX_SAY_LANG=Russian: engine got %q, want %q", got, want)
	}
}

// The buffered route (voxcpm2) normalizes before the adapter builds the
// engine request: the recorded input carries words, not digits.
func TestSpeechVoxCPM2ExpandsRussianNumbers(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	rec := postSpeech(d, `{"input":"Мне 25 лет","model":"voxcpm2"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, bodyText(rec))
	}
	reqs := voxLog(t, logPath)
	if len(reqs) != 1 || reqs[0]["input"] != "Мне двадцать пять лет" {
		t.Fatalf("voxcpm2 requests %v", reqs)
	}
}

// SynthesizeWAV is the shared synthesis entry and normalizes like Speak.
func TestSynthesizeWAVExpandsRussianNumbers(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	if _, err := d.SynthesizeWAV(context.Background(), map[string]any{"input": "Мне 25 лет"}); err != nil {
		t.Fatal(err)
	}
	if got, want := lastSpeechInput(t, dir), "Мне двадцать пять лет"; got != want {
		t.Fatalf("SynthesizeWAV: engine got %q, want %q", got, want)
	}
}
