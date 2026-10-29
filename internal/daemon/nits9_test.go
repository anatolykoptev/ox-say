package daemon

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
)

// #143.6: digits are spoken as words ("2026" -> "twenty twenty-six"), so a
// digit-heavy English line must not get the budget of four characters.
// Mutation: voxcpm2.go buildVoxCPM2, `budgetSec: lengthBudget(input)` ->
// `budgetSec: budgetBaseSec + float64(utf8.RuneCountInString(input))/budgetCharsPerSec` -> RED.
func TestVoxBudgetCountsDigitsAsSpoken(t *testing.T) {
	plain, err := buildVoxCPM2(map[string]any{"input": "In the year"}, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	digits, err := buildVoxCPM2(map[string]any{"input": "In 2026"}, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	// "In " is 3 chars, "2026" is 4 digits.
	want := budgetBaseSec + float64(3+4*spokenCharsPerDigit)/budgetCharsPerSec
	if digits.budgetSec != want {
		t.Errorf("digit budget = %v, want %v (each digit counted as %d spoken characters)", digits.budgetSec, want, spokenCharsPerDigit)
	}
	if got, want := plain.budgetSec, budgetBaseSec+11.0/budgetCharsPerSec; got != want {
		t.Errorf("plain budget = %v, want %v (no digits: unchanged)", got, want)
	}
}

// #143.9d: publicError also scrubs speech and MCP errors, so its log line
// must not say "design:".
// Mutation: design.go publicError, the Warn message back to "design: error ..." -> RED.
func TestPublicErrorLogLabelIsNeutral(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	var buf bytes.Buffer
	d.log = slog.New(slog.NewTextHandler(&buf, nil))
	out := d.publicError(errors.New("engine said: cannot open /Users/someone/secret/ref.wav"))
	if strings.Contains(out.Error(), "/Users/someone") {
		t.Fatalf("path leaked: %v", out)
	}
	if !strings.Contains(buf.String(), "error with a path withheld") {
		t.Fatalf("no withheld-path log line: %s", buf.String())
	}
	if strings.Contains(buf.String(), "design:") {
		t.Errorf("log line is labelled as design: %s", buf.String())
	}
}

// #151.3: the levelled file keeps the input's sample format; 16-bit stays
// 16-bit, anything else is not squeezed to pcm_s16le.
// Mutation: loudness.go renderLevel, `levelCodec(src)` -> `"pcm_s16le"` -> RED (float32 row).
func TestRenderLevelKeepsTheSampleFormat(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		name string
		wav  []byte
		want string
	}{
		{"16-bit", wavWith(16, 1), "pcm_s16le"},
		{"24-bit", wavWith(24, 1), "pcm_s24le"},
		{"32-bit int", wavWith(32, 1), "pcm_s32le"},
		{"float32", wavWith(32, 3), "pcm_f32le"},
		{"float64", wavWith(64, 3), "pcm_f64le"},
		{"garbage", []byte("not a wav"), "pcm_s16le"},
	} {
		args := renderArgs(loudnormSource{wav: tc.wav}, filepath.Join(dir, "o.wav"), 24000, "volume=1dB")
		if got := argAfter(args, "-c:a"); got != tc.want {
			t.Errorf("%s: -c:a %q, want %q (argv %v)", tc.name, got, tc.want, args)
		}
	}
	// A file source is probed from disk.
	p := filepath.Join(dir, "in.wav")
	if err := os.WriteFile(p, wavWith(32, 3), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := argAfter(renderArgs(loudnormSource{path: p}, filepath.Join(dir, "o.wav"), 24000, "volume=1dB"), "-c:a"); got != "pcm_f32le" {
		t.Errorf("file source: -c:a %q, want pcm_f32le", got)
	}
}

func argAfter(args []string, flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

// wavWith is a 44-byte-header WAV (format tag fmtTag, bits per sample, mono,
// 24 kHz) holding a few silent samples.
func wavWith(bits, fmtTag int) []byte {
	b := make([]byte, 44+bits/8*4)
	copy(b, "RIFF")
	copy(b[8:], "WAVEfmt ")
	b[16] = 16
	b[20] = byte(fmtTag)
	b[22] = 1
	rate := 24000
	b[24], b[25], b[26] = byte(rate), byte(rate>>8), byte(rate>>16)
	b[34] = byte(bits)
	copy(b[36:], "data")
	b[40] = byte(bits / 8 * 4)
	return b
}

// #338.c1: a speak stamps its send order only once the engine is ready, just
// before the request is written to the child; a stamp taken while the child is
// still starting would order the request before ones the child receives first.
// Mutation: speak.go speechOn, a `g.MarkSent()` call inserted before
// `sup.EnsureReady(ctx)` -> RED (the stamp exists while the child starts).
func TestSpeakStampsSendOrderAfterEnsureReady(t *testing.T) {
	d, _ := voxFixtureTuned(t, nil)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "1500")
	done := make(chan error, 1)
	go func() {
		_, err := d.speechOn(context.Background(), d.VoxSup, map[string]any{"model": "voxcpm2", "input": "hello there"})
		done <- err
	}()
	deadline := time.Now().Add(10 * time.Second)
	for d.VoxSup.Status().State != engine.StateStarting {
		if time.Now().After(deadline) {
			t.Fatalf("the child never reached starting (state %s)", d.VoxSup.Status().State)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if n := d.VoxSup.SendSeq(); n != 0 {
		t.Errorf("send stamp %d taken while the child was still starting, want 0", n)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if n := d.VoxSup.SendSeq(); n != 1 {
		t.Errorf("send stamp %d after the speak, want 1", n)
	}
}
