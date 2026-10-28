package daemon

import (
	"bytes"
	"context"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// #151.1: a hung ffmpeg is reported as "took too long", not as a failure.
// Mutation: postprocess.go normalizeLoudness, `case errors.Is(ctx.Err(),
// context.DeadlineExceeded):` -> `case false:` -> warnFFmpegFailed -> RED.
func TestHungFFmpegSaysItWasSlow(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	useFakeFFmpeg(t, "exec /bin/sleep 30")
	prev := loudnormTimeout
	loudnormTimeout = 300 * time.Millisecond
	t.Cleanup(func() { loudnormTimeout = prev })
	if _, warn := d.normalizeLoudness(context.Background(), toneBytes(testutil.QwenRate), testTargetLUFS); warn != warnFFmpegSlow {
		t.Errorf("warning %q, want %q", warn, warnFFmpegSlow)
	}
}

// #151.6: a cancelled caller is not an ffmpeg failure: DEBUG, and its own warning.
// Mutation: postprocess.go normalizeLoudness, drop the context.Canceled case
// -> the cancel is logged at WARN with warnFFmpegFailed -> RED.
func TestCancelledNormalisationIsNotAFailure(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	useFakeFFmpeg(t, "exec /bin/sleep 30")
	buf := logBuf(d)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(200 * time.Millisecond); cancel() }()
	take := toneBytes(testutil.QwenRate)
	got, warn := d.normalizeLoudness(ctx, take, testTargetLUFS)
	if !bytes.Equal(got, take) || warn != warnCancelled {
		t.Errorf("kept=%v warning %q, want %q", bytes.Equal(got, take), warn, warnCancelled)
	}
	if strings.Contains(buf.String(), "level=WARN") {
		t.Errorf("a client cancel was logged as a warning: %s", buf.String())
	}
}

// #151.4: a streaming-style header (data size 0xFFFFFFFF) is clamped to the
// bytes that exist, not read as a 44739 s take.
// Mutation: speak.go wavInfoSized, drop the clamp -> RED.
func TestWavInfoClampsDataSizeToTheBytesPresent(t *testing.T) {
	wav := testutil.ToneWAV(testutil.QwenRate, 1, testutil.ToneAmp)
	binary.LittleEndian.PutUint32(wav[40:44], 0xFFFFFFFF) // canonical 44-byte header: data size
	_, secs := wavInfo(wav)
	if secs < 0.9 || secs > 1.1 {
		t.Errorf("duration %.1f s, want about 1 s", secs)
	}
	// The file variant reads only a head of the file: it clamps to the file size.
	p := filepath.Join(t.TempDir(), "s.wav")
	if err := os.WriteFile(p, wav, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, secs := wavInfoFile(p); secs < 0.9 || secs > 1.1 {
		t.Errorf("file duration %.1f s, want about 1 s", secs)
	}
}

// #151.5: stale normalisation temps are swept; fresh ones (a live ffmpeg) and
// other files stay.
// Mutation: loudness.go sweepLoudnormTemps, drop the age check -> the fresh
// temp is removed -> RED; drop the prefix check -> the cache file goes -> RED.
func TestSweepLoudnormTemps(t *testing.T) {
	dir := t.TempDir()
	old := time.Now().Add(-2 * time.Hour)
	put := func(name string, mt time.Time) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
		return p
	}
	stale, staleTry := put(".loudnorm-1.wav", old), put(".loudnorm-1.wav.try", old)
	fresh, other := put(".loudnorm-2.wav", time.Now()), put("take.wav", old)
	if n := sweepLoudnormTemps(dir, time.Hour); n != 2 {
		t.Errorf("swept %d, want 2", n)
	}
	for p, want := range map[string]bool{stale: false, staleTry: false, fresh: true, other: true} {
		if _, err := os.Stat(p); (err == nil) != want {
			t.Errorf("%s exists=%v, want %v", filepath.Base(p), err == nil, want)
		}
	}
}
