package stt

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

var testBoost = Boost{Alpha: 2, Terms: []string{"OxSay\t1\tОкс Сей\tОксей", "Devin\t1"}}

func TestBoostEncoding(t *testing.T) {
	var got struct {
		Alpha float64  `json:"alpha"`
		Terms []string `json:"terms"`
	}
	if err := json.Unmarshal(testBoost.JSON(MaxBodyBytes), &got); err != nil || got.Alpha != 2 || len(got.Terms) != 2 || got.Terms[0] != testBoost.Terms[0] {
		t.Fatalf("JSON round trip = %+v, %v", got, err)
	}
	raw, err := base64.RawURLEncoding.DecodeString(testBoost.Header())
	if err != nil || !strings.Contains(string(raw), `"alpha":2`) {
		t.Fatalf("header is not base64url JSON: %q %v", raw, err)
	}
	if testBoost.Stdin() != "OxSay\t1\tОкс Сей\tОксей\nDevin\t1\n" {
		t.Fatalf("stdin = %q", testBoost.Stdin())
	}
	for name, b := range map[string]Boost{
		"alpha 0": {Alpha: 0, Terms: testBoost.Terms}, "no terms": {Alpha: 2}, "over cap": {Alpha: 101, Terms: testBoost.Terms},
	} {
		if b.Active() || b.JSON(MaxBodyBytes) != nil || b.Header() != "" {
			t.Fatalf("%s: inactive boost must encode to nothing", name)
		}
	}
}

// A list that does not fit drops its tail (the least recent terms) rather than the whole boost.
func TestBoostHeaderTrimsToFit(t *testing.T) {
	var terms []string
	for i := 0; i < 400; i++ {
		terms = append(terms, fmt.Sprintf("Term%03d\t1\tтермин%03d", i, i))
	}
	b := Boost{Alpha: 2, Terms: terms}
	h := b.Header()
	if h == "" || len(h) > MaxHeaderBytes {
		t.Fatalf("header len = %d, want 1..%d", len(h), MaxHeaderBytes)
	}
	raw, _ := base64.RawURLEncoding.DecodeString(h)
	var got struct{ Terms []string }
	if err := json.Unmarshal(raw, &got); err != nil || len(got.Terms) == 0 || len(got.Terms) >= 400 || got.Terms[0] != terms[0] {
		t.Fatalf("trimmed header: %d terms, err %v; the head must survive", len(got.Terms), err)
	}
	if len(b.JSON(MaxBodyBytes)) > MaxBodyBytes {
		t.Fatal("body over its cap")
	}
}

// The CLI path gets the terms on stdin and --boost-alpha, never in argv.
func TestCLIGetsTermsOnStdin(t *testing.T) {
	dir := t.TempDir()
	opts, log := fakeOpts(t, dir)
	stdin := filepath.Join(dir, "stdin.txt")
	t.Setenv("OXSAY_FAKE_STT_STDIN", stdin)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")
	opts.Boost = testBoost
	if _, err := Transcribe(context.Background(), src, opts); err != nil {
		t.Fatal(err)
	}
	runs := sttRuns(t, log)
	args := runs[len(runs)-1].args
	if !hasArg(args, "--terms-stdin") || !hasArg(args, "--boost-alpha") || !hasArg(args, "2") {
		t.Fatalf("argv %v missing --terms-stdin --boost-alpha 2", args)
	}
	for _, a := range args {
		if strings.Contains(a, "OxSay") || strings.Contains(a, "Окс") {
			t.Fatalf("a term reached argv: %q", a)
		}
	}
	got, err := os.ReadFile(stdin)
	if err != nil || string(got) != testBoost.Stdin() {
		t.Fatalf("stdin = %q, %v", got, err)
	}

	// no boost: no flags
	opts.Boost = Boost{}
	if _, err := Transcribe(context.Background(), src, opts); err != nil {
		t.Fatal(err)
	}
	runs = sttRuns(t, log)
	if hasArg(runs[len(runs)-1].args, "--terms-stdin") {
		t.Fatal("an empty boost must not add --terms-stdin")
	}
}

// The resident-server path sends X-Ox-Terms on POST /transcribe.
func TestServerGetsTermsHeader(t *testing.T) {
	dir := t.TempDir()
	opts, _ := fakeOpts(t, dir)
	var hdr string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hdr = r.Header.Get("X-Ox-Terms")
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintln(w, `{"engine":"parakeet","duration_s":1,"text":"via server"}`)
	}))
	defer srv.Close()
	opts.Server = func(context.Context) (string, func(), error) { return srv.URL, func() {}, nil }
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	opts.Boost = testBoost
	if res, err := Transcribe(context.Background(), src, opts); err != nil || res.Text != "via server" {
		t.Fatalf("res = %+v, %v", res, err)
	}
	if hdr != testBoost.Header() || hdr == "" {
		t.Fatalf("X-Ox-Terms = %q, want %q", hdr, testBoost.Header())
	}
	hdr = "unset"
	opts.Boost = Boost{}
	if _, err := Transcribe(context.Background(), src, opts); err != nil {
		t.Fatal(err)
	}
	if hdr != "" {
		t.Fatalf("an empty boost sent X-Ox-Terms = %q", hdr)
	}
}
