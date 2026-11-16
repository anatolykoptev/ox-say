package stt

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
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

// An older ox-stt rejects --terms-stdin with a usage error (exit 2): the transcription must still happen, once,
// unboosted.
// Mutation: stt.go, drop the usage-error retry -> RED (the error reaches the caller).
func TestCLIRetriesUnboostedOnUsageError(t *testing.T) {
	dir := t.TempDir()
	opts, log := fakeOpts(t, dir)
	t.Setenv("OXSAY_FAKE_STT_REJECT_TERMS", "1")
	src := testutil.WriteTinyWAV(t, dir, "in.wav")
	opts.Boost = testBoost
	res, err := Transcribe(context.Background(), src, opts)
	if err != nil || res.Text != "hello world." {
		t.Fatalf("res = %+v, err = %v; want the unboosted retry's result", res, err)
	}
	runs := sttRuns(t, log)
	if len(runs) != 2 || !hasArg(runs[0].args, "--terms-stdin") || hasArg(runs[1].args, "--terms-stdin") || hasArg(runs[1].args, "--boost-alpha") {
		t.Fatalf("runs = %+v, want one boosted attempt then one without the flags", runs)
	}
}

// The usage-error retry says so, once per process, and never prints a term. An engine older than the daemon is
// otherwise invisible: every dictation silently loses its glossary list.
// Mutation: stt.go, drop the slog.Warn in the usage-error retry -> RED.
func TestCLIUnboostedRetryIsLogged(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })
	warnedUnboosted.Store(false)

	dir := t.TempDir()
	opts, _ := fakeOpts(t, dir)
	t.Setenv("OXSAY_FAKE_STT_REJECT_TERMS", "1")
	src := testutil.WriteTinyWAV(t, dir, "in.wav")
	opts.Boost = testBoost
	for i := 0; i < 2; i++ {
		if _, err := Transcribe(context.Background(), src, opts); err != nil {
			t.Fatal(err)
		}
	}
	got := buf.String()
	if strings.Count(got, "without the glossary list") != 1 {
		t.Fatalf("log = %q, want the retry reported exactly once", got)
	}
	for _, term := range []string{"OxSay", "Окс", "Devin"} {
		if strings.Contains(got, term) {
			t.Fatalf("a term reached the log: %q", got)
		}
	}
}

// Every delivery path carries the same prefix of the list, and the cut is countable: the CLI used to get all
// terms while the server paths got the trimmed list, so a long glossary behaved differently per path.
// Mutation: boost.go, Stdin ranging over b.Terms instead of b.Terms[:b.Fit(MaxWireJSON)] -> RED.
func TestAllPathsCarryTheSameFit(t *testing.T) {
	var terms []string
	for i := 0; i < 400; i++ {
		terms = append(terms, fmt.Sprintf("Term%03d\t1\tтермин%03d", i, i))
	}
	b := Boost{Alpha: 2, Terms: terms}
	n := b.Fit(MaxWireJSON)
	if n == 0 || n >= len(terms) || b.Dropped() != len(terms)-n {
		t.Fatalf("Fit = %d of %d, Dropped = %d", n, len(terms), b.Dropped())
	}
	if got := strings.Count(b.Stdin(), "\n"); got != n {
		t.Fatalf("stdin carries %d terms, the wire carries %d", got, n)
	}
	var w struct{ Terms []string }
	if err := json.Unmarshal(b.JSON(MaxWireJSON), &w); err != nil || len(w.Terms) != n {
		t.Fatalf("JSON carries %d terms (%v), want %d", len(w.Terms), err, n)
	}
	// the one more term that would not fit really does not fit
	if over, _ := json.Marshal(struct {
		Alpha float64  `json:"alpha"`
		Terms []string `json:"terms"`
	}{2, terms[:n+1]}); len(over) <= MaxWireJSON {
		t.Fatalf("Fit stopped at %d but %d terms still fit (%d bytes)", n, n+1, len(over))
	}
	if (Boost{Alpha: 2, Terms: terms[:3]}).Dropped() != 0 {
		t.Fatal("a short list drops nothing")
	}
}
