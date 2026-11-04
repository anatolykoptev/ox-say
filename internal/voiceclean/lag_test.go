package voiceclean

import (
	"math"
	"path/filepath"
	"testing"
)

// makeOffsetClip is a clip whose audio (aOff) and/or picture (vOff) start late on the timeline.
func makeOffsetClip(t *testing.T, ext, vcodec, acodec string, vOff, aOff float64) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "in."+ext)
	args := []string{"-itsoffset", ftoa(vOff), "-f", "lavfi", "-i", "testsrc=size=160x120:rate=25:duration=3",
		"-itsoffset", ftoa(aOff), "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
		"-c:v", vcodec, "-c:a", acodec, "-avoid_negative_ts", "disabled"}
	if ext == "mp4" || ext == "mov" {
		args = append(args, "-movflags", "+faststart")
	}
	ffrun(t, append(args, p)...)
	return p
}

func ftoa(f float64) string { return formatF(f) }

// One AAC frame is 1024/48000 = 0.0213 s; the lag between audio and picture must survive with 5 ms to spare (the audio is not at the 1/48000 grid of the input).
func TestAVLagSurvivesCleaningInEveryContainer(t *testing.T) {
	requireTools(t)
	type c struct {
		ext, v, a  string
		vOff, aOff float64
	}
	for _, cs := range []c{
		{"mp4", "mpeg4", "aac", 0, 1.5}, {"mov", "mpeg4", "aac", 0, 1.5}, {"mkv", "mpeg4", "aac", 0, 1.5},
		{"webm", "libvpx", "libopus", 0, 1.5},
		{"mp4", "mpeg4", "aac", 1.0, 0}, {"mkv", "mpeg4", "aac", 1.0, 0},
		{"mp4", "mpeg4", "aac", 0, 0}, {"mp4", "mpeg4", "aac", 1.0, 1.5}, {"mkv", "mpeg4", "aac", 0, -0.5},
	} {
		name := cs.ext + "_v" + ftoa(cs.vOff) + "_a" + ftoa(cs.aOff)
		t.Run(name, func(t *testing.T) {
			requireEncoder(t, cs.v)
			requireEncoder(t, cs.a)
			in := makeOffsetClip(t, cs.ext, cs.v, cs.a, cs.vOff, cs.aOff)
			o := opts(t, in, filepath.Join(t.TempDir(), "o."+cs.ext), 0.85, fakeEngine(t, "1"))
			mustRun(t, o)
			lagIn := startTime(t, in, "a:0") - startTime(t, in, "v:0")
			lagOut := startTime(t, o.Out, "a:0") - startTime(t, o.Out, "v:0")
			t.Logf("input lag %.4f output lag %.4f (a %.4f -> %.4f)", lagIn, lagOut, startTime(t, in, "a:0"), startTime(t, o.Out, "a:0"))
			if math.Abs(lagOut-lagIn) > 0.005 {
				t.Errorf("A/V lag moved by %.4f s (input %.4f, output %.4f)", lagOut-lagIn, lagIn, lagOut)
			}
		})
	}
}
