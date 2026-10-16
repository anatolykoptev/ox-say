package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// The assembly's ffmpeg pace bounds.
const (
	// paceTimeout bounds one stretch: a whole take, seconds of audio.
	paceTimeout = 2 * time.Minute
	// paceProbeTimeout bounds the one-time capability check.
	paceProbeTimeout = 30 * time.Second
	// paceWAVPattern keeps a stretched clip a swept hidden temp under the
	// job's out/ — never takes/.
	paceWAVPattern = ".pace" + vproject.TempMark + "*.wav"
	// paceSlackSec forgives atempo's window quantization (a few ms): a real
	// miss — a no-op stretch — is off by the chunk's whole delta.
	paceSlackSec = 0.03
)

// paceStretch is the stretcher stream hands tl.add: the trimmed clip and
// the rate go in, the stretched clip comes out.
type paceStretch func(pcm.Clip, float64) (pcm.Clip, error)

// paceOK is the cached answer to "can this machine time-stretch": one
// `ffmpeg -filters` listing scanned for atempo. A pace op on a host whose
// ffmpeg is missing or lacks the filter is refused at op time; a project
// with no paced chunk never pays the probe.
var paceOK = sync.OnceValue(func() error {
	ctx, cancel := context.WithTimeout(context.Background(), paceProbeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ffmpeg", "-hide_banner", "-filters").Output()
	if err != nil {
		return errors.New("a pace change needs ffmpeg, which is missing or cannot run here (brew install ffmpeg)")
	}
	for line := range strings.Lines(string(out)) {
		if f := strings.Fields(line); len(f) >= 2 && f[1] == "atempo" {
			return nil
		}
	}
	return errors.New("a pace change needs ffmpeg's atempo filter, which this ffmpeg build does not have")
})

// atempoClip returns clip (already trimmed, at clip.Rate) stretched by
// rate: one ffmpeg atempo, the WAV in on stdin, the result read back from
// a temp file under work that is removed whatever happens next.
func atempoClip(ctx context.Context, work string, clip pcm.Clip, rate float64) (pcm.Clip, error) {
	f, err := os.CreateTemp(work, paceWAVPattern)
	if err != nil {
		return pcm.Clip{}, err
	}
	tmp := f.Name()
	_ = f.Close()
	defer func() { _ = os.Remove(tmp) }()
	ctx, cancel := context.WithTimeout(ctx, paceTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ffmpeg", "-hide_banner", "-nostats", "-loglevel", "error", "-y",
		"-f", "wav", "-i", "pipe:0",
		"-af", "atempo="+strconv.FormatFloat(rate, 'g', -1, 64),
		"-ar", strconv.Itoa(clip.Rate), "-c:a", "pcm_s16le", "-f", "wav", tmp)
	cmd.Stdin = bytes.NewReader(clip.Encode())
	cmd.WaitDelay = loudnormWaitDelay
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return pcm.Clip{}, fmt.Errorf("ffmpeg atempo: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	out, err := readClip(tmp)
	if err != nil {
		return pcm.Clip{}, fmt.Errorf("ffmpeg atempo: %w", err)
	}
	if out.Rate != clip.Rate || math.Abs(out.Seconds()-clip.Seconds()/rate) > paceSlackSec {
		return pcm.Clip{}, fmt.Errorf("ffmpeg atempo produced %d Hz / %.2f s, want %d Hz / %.2f s of audio", out.Rate, out.Seconds(), clip.Rate, clip.Seconds()/rate)
	}
	return out, nil
}
