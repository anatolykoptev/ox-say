package meeting

import (
	"context"
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"testing"
)

// The integration test runs the REAL ox-aec on synthetic audio: it is skipped unless OX_AEC_BIN names the binary
// (built by engine/build.sh). The far side is a deterministic coloured noise; the mic hears it back 50 ms later at
// 0.4 gain and nothing else, so everything in the capture is echo.
const (
	aecEnvBin       = "OX_AEC_BIN"
	aecSynthSeconds = 30
	aecSynthLagMS   = 50
	aecSynthGain    = 0.4
	aecSynthPeak    = 18000.0
	aecSynthPole    = 0.9 // one-pole low-pass: noise with speech-like tilt
	aecSettleSecs   = 15  // the canceller needs time to converge; energy is compared after it
	aecWantRatio    = 0.5 // residual RMS over the settled stretch must be at most this share of the input's
	aecLCGMul       = 1103515245
	aecLCGAdd       = 12345
)

// synthEcho returns the far-side channel and the mic channel that hears only its echo.
func synthEcho() (render, capture []int16) {
	n := aecSynthSeconds * SampleRate
	render, capture = make([]int16, n), make([]int16, n)
	lag := aecSynthLagMS * SampleRate / 1000
	var seed uint32 = 1
	var lp float64
	for i := range render {
		seed = seed*aecLCGMul + aecLCGAdd
		white := float64(seed>>16)/32768.0 - 1.0
		lp = aecSynthPole*lp + (1-aecSynthPole)*white
		render[i] = int16(lp * aecSynthPeak)
	}
	for i := lag; i < n; i++ {
		capture[i] = int16(float64(render[i-lag]) * aecSynthGain)
	}
	return render, capture
}

func writeS16(t *testing.T, path string, s []int16) {
	t.Helper()
	b := make([]byte, len(s)*bytesPerSample)
	for i, v := range s {
		binary.LittleEndian.PutUint16(b[i*bytesPerSample:], uint16(v))
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func readS16(t *testing.T, path string) []int16 {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := make([]int16, len(b)/bytesPerSample)
	for i := range s {
		s[i] = int16(binary.LittleEndian.Uint16(b[i*bytesPerSample:]))
	}
	return s
}

func rms(s []int16) float64 {
	var sum float64
	for _, v := range s {
		sum += float64(v) * float64(v)
	}
	return math.Sqrt(sum / float64(len(s)))
}

// With the real binary: me.aec.pcm is the capture's length (the same index is the same instant), the echo left in
// the settled stretch is well below what the mic heard, me.pcm is untouched, and the report says what the stage logs.
func TestAECRealBinaryCancelsASyntheticEcho(t *testing.T) {
	bin := os.Getenv(aecEnvBin)
	if bin == "" {
		t.Skipf("%s is not set: no real ox-aec to run", aecEnvBin)
	}
	dir := t.TempDir()
	render, capture := synthEcho()
	writeS16(t, filepath.Join(dir, ThemPCM), render)
	writeS16(t, filepath.Join(dir, MePCM), capture)
	before, err := os.ReadFile(filepath.Join(dir, MePCM))
	if err != nil {
		t.Fatal(err)
	}
	rep, err := RunAECBin(context.Background(), bin, dir)
	if err != nil {
		t.Fatalf("RunAECBin: %v", err)
	}
	out := readS16(t, filepath.Join(dir, MeAECPCM))
	if len(out) != len(capture) {
		t.Fatalf("me.aec.pcm has %d samples, the capture %d", len(out), len(capture))
	}
	from := aecSettleSecs * SampleRate
	in, res := rms(capture[from:]), rms(out[from:])
	if res > in*aecWantRatio {
		t.Fatalf("settled residual rms %.1f vs input %.1f (ratio %.2f), want at most %.2f", res, in, res/in, aecWantRatio)
	}
	after, err := os.ReadFile(filepath.Join(dir, MePCM))
	if err != nil || string(after) != string(before) {
		t.Fatal("me.pcm was modified")
	}
	if rep.Diverged || rep.Skipped != "" {
		t.Fatalf("report = %+v, want a clean run", rep)
	}
	v := reportVerdict(rep, dir)
	if v.result != stageOK || !v.useAEC {
		t.Fatalf("verdict = %+v, want ok and reading me.aec.pcm", v)
	}
	if v.run.LagMS == nil || v.run.ERLEdB == nil {
		t.Fatalf("the stage's numbers are missing: %+v", v.run)
	}
	t.Logf("alignment=%s lag_ms=%.1f erle_db=%.1f residual/input=%.3f", rep.Alignment, *v.run.LagMS, *v.run.ERLEdB, res/in)
}
