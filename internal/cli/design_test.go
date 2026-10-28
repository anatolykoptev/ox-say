package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const designReply = `{"description":"warm","text":"Привет.","save_hint":"x","takes":[` +
	`{"path":"/c/design/a-1.wav","seed":1,"duration_s":2.5,"suggested_name":"warm-1"},` +
	`{"path":"/c/it's/a-2.wav","seed":2,"duration_s":3,"suggested_name":"warm-2","warning":"may contain babble"}]}`

// stubDaemon answers every request with reply and records path and body.
func stubDaemon(t *testing.T, reply string) (path *string, body *map[string]any) {
	t.Helper()
	var p string
	var b map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&b)
		_, _ = w.Write([]byte(reply))
	}))
	t.Cleanup(srv.Close)
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	return &p, &b
}

// `voice design` sends the description, text, takes and seed to the design
// route, prints one line per take (path and seed) and the exact save command.
// Mutation: cmdVoiceDesign, drop the "take %d seed" print -> RED.
func TestVoiceDesignPrintsTakesAndSaveCommand(t *testing.T) {
	path, body := stubDaemon(t, designReply)
	var out, errb strings.Builder
	code := Run([]string{"voice", "design", "warm voice", "-t", "Привет.", "-n", "2", "--seed", "1"}, &out, &errb, "test")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if *path != "/v1/audio/voices/design" || (*body)["description"] != "warm voice" || (*body)["text"] != "Привет." ||
		(*body)["takes"] != float64(2) || (*body)["seed"] != float64(1) {
		t.Fatalf("request %s %v", *path, *body)
	}
	want := `take 1  seed 1  2.5s  /c/design/a-1.wav
take 2  seed 2  3.0s  /c/it's/a-2.wav  (warning: may contain babble)
save one:
  ox-say voice save warm-1 '/c/design/a-1.wav'
  ox-say voice save warm-2 '/c/it'\''s/a-2.wav'
`
	if out.String() != want {
		t.Fatalf("output:\n%s\nwant:\n%s", out.String(), want)
	}
}

// A design needs a description and text; nothing is sent without them.
func TestVoiceDesignUsage(t *testing.T) {
	path, _ := stubDaemon(t, designReply)
	for _, args := range [][]string{{"voice", "design"}, {"voice", "design", "warm"}, {"voice", "design", "-t", "x"}} {
		var out, errb strings.Builder
		if code := Run(args, &out, &errb, "test"); code != 2 || !strings.Contains(errb.String(), "usage: ox-say voice design") {
			t.Errorf("%v: exit %d %q", args, code, errb.String())
		}
	}
	if *path != "" {
		t.Errorf("a malformed command reached the daemon: %s", *path)
	}
}

// `voice save` sends the name and an absolute take path to the save route and
// nothing else (the daemon owns the metadata).
func TestVoiceSaveSendsNameAndTake(t *testing.T) {
	path, body := stubDaemon(t, `{"name":"ru-host","engine":"voxcpm2","designed_from":"warm","seed":2}`)
	var out, errb strings.Builder
	if code := Run([]string{"voice", "save", "ru-host", "/c/design/a-2.wav"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if *path != "/v1/audio/voices/design/save" || len(*body) != 3 || (*body)["name"] != "ru-host" || (*body)["take"] != "/c/design/a-2.wav" {
		t.Fatalf("request %s %v", *path, *body)
	}
	if !strings.Contains(out.String(), `voice "ru-host" saved`) {
		t.Fatalf("stdout %q", out.String())
	}
}

// --replace reaches the daemon as replace:true, and only then.
func TestVoiceSaveReplaceFlag(t *testing.T) {
	_, body := stubDaemon(t, `{"name":"x","seed":1}`)
	var out, errb strings.Builder
	if code := Run([]string{"voice", "save", "--replace", "x", "/c/a.wav"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if (*body)["replace"] != true {
		t.Fatalf("body %v", *body)
	}
}

// `-n 0` is refused here instead of silently meaning the daemon's default of 3.
// Mutation: cmdVoiceDesign, delete the `n < 1` check -> the request is sent
// with takes 0 -> RED.
func TestVoiceDesignRefusesZeroTakes(t *testing.T) {
	path, _ := stubDaemon(t, designReply)
	for _, n := range []string{"0", "-1"} {
		var out, errb strings.Builder
		code := Run([]string{"voice", "design", "warm voice", "-t", "Привет.", "-n", n}, &out, &errb, "test")
		if code != 2 || !strings.Contains(errb.String(), "-n") || *path != "" {
			t.Errorf("-n %s: exit %d, stderr %q, daemon called %q; want exit 2 and no request", n, code, errb.String(), *path)
		}
	}
}
