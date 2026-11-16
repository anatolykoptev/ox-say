package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// A voice add whose ref_text check ran into a busy speech-to-text stores the text as given and says so, on every
// surface that answers an add: a caller that sees ref_text_unchecked can retry; without it the partial-read bug
// the check exists for would come back with no signal (#440). An add with nothing to check against stays silent.
//
// Mutations: http.go handleAddVoice, `if v.RefTextUnchecked {` -> `if false {` -> RED
// (TestAddVoiceHTTPReportsAnUncheckedRefText); mcp.go toolVoiceAdd, drop `RefTextUnchecked: v.RefTextUnchecked`
// -> RED (TestAddVoiceMCPReportsAnUncheckedRefText); design.go saveDesignResult, drop the same field
// -> RED (TestSaveDesignedVoiceReportsAnUncheckedRefText).
func sttBusy(context.Context, string) ([]voices.Word, error) { return nil, errors.New("stt: busy") }

func TestAddVoiceHTTPReportsAnUncheckedRefText(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	post := func(name string) map[string]any {
		src := testutil.WriteSilentWAV(t, dir, name+".wav", 8)
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
	// No transcriber: nothing to check against, permanent, nothing to report.
	if m := post("nocheck"); m["ref_text_unchecked"] != nil || len(m) != 3 {
		t.Fatalf("no transcriber: response = %v, want exactly name/status/registered_to_engine", m)
	}
	d.Store.SetTranscriber(sttBusy)
	if m := post("busy"); m["ref_text_unchecked"] != true {
		t.Fatalf("busy STT: response = %v, want ref_text_unchecked true", m)
	}
}

func TestAddVoiceMCPReportsAnUncheckedRefText(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	src := testutil.WriteSilentWAV(t, dir, "mcp.wav", 8)
	d.Store.SetTranscriber(sttBusy)
	_, out, err := d.toolVoiceAdd(context.Background(), nil, voiceAddIn{Name: "mcp", AudioPath: src, RefText: "typed by hand"})
	if err != nil {
		t.Fatal(err)
	}
	if !out.RefTextUnchecked {
		t.Fatalf("out = %+v, want RefTextUnchecked", out)
	}
	raw, _ := json.Marshal(out)
	if !bytes.Contains(raw, []byte(`"ref_text_unchecked":true`)) {
		t.Fatalf("tool answer %s lacks ref_text_unchecked", raw)
	}
}

func TestSaveDesignedVoiceReportsAnUncheckedRefText(t *testing.T) {
	d, _, _ := designFixture(t)
	res := designThree(t, d)
	d.Store.SetTranscriber(sttBusy)
	saved, err := d.saveDesignResult(context.Background(), SaveDesignInput{Name: "kept", Take: res.Takes[0].Path})
	if err != nil {
		t.Fatal(err)
	}
	if !saved.RefTextUnchecked {
		t.Fatalf("saved = %+v, want RefTextUnchecked", saved)
	}
}
