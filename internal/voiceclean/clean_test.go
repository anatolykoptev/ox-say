package voiceclean

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestIdentityEngineReturnsTheInputWhateverTheWet(t *testing.T) { // mid add-back with e == m changes nothing
	requireTools(t)
	in := makeStereoWav(t, 44100, 3.0)
	for _, w := range []float64{0, 0.85, 1} {
		o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), w, fakeEngine(t, "1"))
		r := mustRun(t, o)
		if r.Stereo != "mid" || r.SampleRate != 44100 || r.Channels != 2 || r.Video || r.Wet != w {
			t.Errorf("result %+v", r)
		}
		if d := rmsDiffDB(t, in, o.Out); d > -70 {
			t.Errorf("wet %v: residual %.1f dB, want <= -70", w, d)
		}
		noLeftovers(t, o)
	}
}

func TestIdentityEngineInChannelsMode(t *testing.T) {
	requireTools(t)
	in := makeStereoWav(t, 48000, 2.0)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 1, fakeEngine(t, "1"))
	o.Stereo = "channels"
	if r := mustRun(t, o); r.Stereo != "channels" {
		t.Errorf("stereo %q", r.Stereo)
	}
	if d := rmsDiffDB(t, in, o.Out); d > -70 {
		t.Errorf("residual %.1f dB", d)
	}
}

// A silencing engine at wet 1 returns silence on each channel; mid mode returns the side signal only. This pins that
// the two modes really differ (channels = every channel replaced, mid = only the centre).
func TestMidKeepsTheSideSignalChannelsDoesNot(t *testing.T) {
	requireTools(t)
	in := makeStereoWav(t, 48000, 2.0) // 440 left, 660 right: all of it is side signal in part
	mid := opts(t, in, filepath.Join(t.TempDir(), "mid.wav"), 1, fakeEngine(t, "0"))
	mustRun(t, mid)
	chs := opts(t, in, filepath.Join(t.TempDir(), "ch.wav"), 1, fakeEngine(t, "0"))
	chs.Stereo = "channels"
	mustRun(t, chs)
	sm, _, _ := decodeF32(t, mid.Out)
	sc, _, _ := decodeF32(t, chs.Out)
	src, _, _ := decodeF32(t, in)
	t.Logf("rms in %.5f mid-mode out %.5f channels-mode out %.5f", rms(src), rms(sm), rms(sc))
	if rms(sc) > 1e-4 {
		t.Errorf("channels mode with a silent engine should be silent, rms %g", rms(sc))
	}
	// out = c - m = (L-R)/2 per channel: for two unrelated tones of equal level that is 1/sqrt(2) of the source's level
	if r := rms(sm) / rms(src); r < 0.65 || r > 0.76 {
		t.Errorf("mid mode must keep the side signal: out/in rms = %.3f, want about 0.707 (the side of two unrelated tones)", r)
	}
}

func TestWetMathWithASilencingEngine(t *testing.T) { // engine returns silence: out = dry * (1 - wet)
	requireTools(t)
	in := makeMonoWav(t, 48000, 2.0)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, fakeEngine(t, "0"))
	mustRun(t, o)
	if r := rmsRatio(t, o.Out, in); math.Abs(r-0.15) > 0.01 {
		t.Fatalf("ratio %.3f, want 0.15", r)
	}
}

func TestRatesAroundTheModelsOwn(t *testing.T) {
	requireTools(t)
	for _, rate := range []int{16000, 22050, 96000} {
		in := makeMonoWav(t, rate, 1.5)
		o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, fakeEngine(t, "1"))
		mustRun(t, o)
		s, ch, got := decodeF32(t, o.Out)
		if ch != 1 || got != rate {
			t.Errorf("%d Hz: output is %d ch %d Hz", rate, ch, got)
		}
		if d := math.Abs(float64(len(s))/float64(rate) - 1.5); d > 0.01 {
			t.Errorf("%d Hz: length moved by %v s", rate, d)
		}
		if d := rmsDiffDB(t, in, o.Out); d > -45 {
			t.Errorf("%d Hz: residual %.1f dB after the 48 kHz detour", rate, d)
		}
		noLeftovers(t, o)
	}
}

func TestVideoKeepsPictureOtherStreamsMetadataChaptersAndTiming(t *testing.T) {
	requireEncoder(t, "mpeg4")
	in := makeMp4(t)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, fakeEngine(t, "1"))
	r := mustRun(t, o)
	if !r.Video || r.Channels != 1 {
		t.Errorf("result %+v", r)
	}
	if md5Of(t, in, "-map", "0:v") != md5Of(t, o.Out, "-map", "0:v") {
		t.Fatal("picture changed")
	}
	if md5Of(t, in, "-map", "0:a:1") != md5Of(t, o.Out, "-map", "0:a:1") {
		t.Fatal("second audio changed")
	}
	if md5Of(t, in, "-map", "0:s") != md5Of(t, o.Out, "-map", "0:s") {
		t.Fatal("subtitles changed")
	}
	if streamLayout(t, in) != streamLayout(t, o.Out) {
		t.Fatalf("stream order or count changed:\n%s\n--\n%s", streamLayout(t, in), streamLayout(t, o.Out))
	}
	if tag(t, in, "title") != tag(t, o.Out, "title") || tag(t, o.Out, "title") == "" {
		t.Fatal("title lost")
	}
	if c := chapters(t, o.Out); chapters(t, in) != c || c == "" {
		t.Fatalf("chapters lost: %q vs %q", chapters(t, in), c)
	}
	lagIn := startTime(t, in, "a:0") - startTime(t, in, "v:0")
	if lag := startTime(t, o.Out, "a:0") - startTime(t, o.Out, "v:0"); math.Abs(lag-lagIn) > 0.001 {
		t.Fatalf("A/V lag moved by %v", lag-lagIn)
	}
	if d := math.Abs(duration(t, o.Out, "a:0") - duration(t, in, "a:0")); d > 0.03 {
		t.Fatalf("audio length moved %v s (one AAC frame is 0.0213)", d)
	}
	noLeftovers(t, o)
}

// Each video container the script knows, and each audio-only output, produces a file ffprobe reads back with the
// cleaned track in it. The fixtures are made in the container they are cleaned into.
func TestEveryOutputContainerIsReadable(t *testing.T) {
	requireTools(t)
	type vcase struct{ ext, vcodec, acodec, want string }
	for _, c := range []vcase{{"mov", "mpeg4", "aac", "aac"}, {"mkv", "mpeg4", "aac", "aac"}, {"webm", "libvpx", "libopus", "opus"}, {"m4v", "mpeg4", "aac", "aac"}} {
		t.Run("video_"+c.ext, func(t *testing.T) {
			requireEncoder(t, c.vcodec)
			requireEncoder(t, c.acodec)
			in := filepath.Join(t.TempDir(), "in."+c.ext)
			ffrun(t, "-f", "lavfi", "-i", "testsrc=size=160x120:rate=25:duration=1", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
				"-c:v", c.vcodec, "-c:a", c.acodec, in)
			o := opts(t, in, filepath.Join(t.TempDir(), "o."+c.ext), 0.85, fakeEngine(t, "1"))
			mustRun(t, o)
			if md5Of(t, in, "-map", "0:v") != md5Of(t, o.Out, "-map", "0:v") {
				t.Error("picture changed")
			}
			if got := fprobe(t, "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", o.Out); got != c.want {
				t.Errorf("audio codec %q", got)
			}
			noLeftovers(t, o)
		})
	}
	for _, c := range []struct{ ext, enc, codec string }{{"flac", "flac", "flac"}, {"mp3", "libmp3lame", "mp3"}, {"m4a", "aac", "aac"}, {"mp4", "aac", "aac"}} {
		t.Run("audio_"+c.ext, func(t *testing.T) {
			requireEncoder(t, c.enc)
			in := makeStereoWav(t, 44100, 1.5)
			o := opts(t, in, filepath.Join(t.TempDir(), "o."+c.ext), 0.85, fakeEngine(t, "1"))
			mustRun(t, o)
			if got := fprobe(t, "-select_streams", "a:0", "-show_entries", "stream=codec_name,channels,sample_rate", "-of", "csv=p=0", o.Out); !strings.HasPrefix(got, c.codec+",44100,2") {
				t.Errorf("stream %q", got)
			}
			noLeftovers(t, o)
		})
	}
}

func TestRefusals(t *testing.T) {
	requireTools(t)
	eng := fakeEngine(t, "1")
	mono := makeMonoWav(t, 48000, 1.0)

	t.Run("out is in, by path", func(t *testing.T) {
		before := sha(t, mono)
		o := opts(t, mono, mono, 0.85, eng)
		o.Overwrite = true
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeSameFile)
		if sha(t, mono) != before {
			t.Fatal("the input changed")
		}
		noLeftovers(t, o)
	})
	t.Run("out is a hard link of in", func(t *testing.T) {
		dir := t.TempDir()
		in, link := filepath.Join(dir, "in.wav"), filepath.Join(dir, "link.wav")
		must(t, os.WriteFile(in, mustRead(t, mono), 0o600))
		must(t, os.Link(in, link))
		o := opts(t, in, link, 0.85, eng)
		o.Overwrite = true
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeSameFile)
		noLeftovers(t, o)
	})
	t.Run("out is a symlink to in", func(t *testing.T) {
		dir := t.TempDir()
		in, link := filepath.Join(dir, "in.wav"), filepath.Join(dir, "link.wav")
		must(t, os.WriteFile(in, mustRead(t, mono), 0o600))
		must(t, os.Symlink(in, link))
		o := opts(t, in, link, 0.85, eng)
		o.Overwrite = true
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeSameFile)
		if fi, e := os.Lstat(link); e != nil || fi.Mode()&os.ModeSymlink == 0 {
			t.Fatal("the link was replaced")
		}
	})
	t.Run("existing out is refused and kept", func(t *testing.T) {
		out := filepath.Join(t.TempDir(), "o.wav")
		must(t, os.WriteFile(out, []byte("precious"), 0o600))
		o := opts(t, mono, out, 0.85, eng)
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeExists)
		if string(mustRead(t, out)) != "precious" {
			t.Fatal("the existing output changed")
		}
		noLeftovers(t, o)
	})
	t.Run("a dangling link counts as existing", func(t *testing.T) {
		out := filepath.Join(t.TempDir(), "o.wav")
		must(t, os.Symlink("/nonexistent/target", out))
		_, err := Run(context.Background(), opts(t, mono, out, 0.85, eng))
		wantCode(t, err, CodeExists)
	})
	t.Run("overwrite replaces it whole", func(t *testing.T) {
		out := filepath.Join(t.TempDir(), "o.wav")
		must(t, os.WriteFile(out, []byte("old"), 0o600))
		o := opts(t, mono, out, 0.85, eng)
		o.Overwrite = true
		mustRun(t, o)
		if d := rmsDiffDB(t, mono, out); d > -70 {
			t.Errorf("replaced output differs from the identity clean: %.1f dB", d)
		}
		noLeftovers(t, o)
	})
	t.Run("overwrite replaces a link, not what it points at", func(t *testing.T) {
		dir := t.TempDir()
		target, out := filepath.Join(dir, "target.wav"), filepath.Join(dir, "o.wav")
		must(t, os.WriteFile(target, []byte("keep me"), 0o600))
		must(t, os.Symlink(target, out))
		o := opts(t, mono, out, 0.85, eng)
		o.Overwrite = true
		mustRun(t, o)
		if string(mustRead(t, target)) != "keep me" {
			t.Fatal("the link's target was written through")
		}
	})
	t.Run("no audio", func(t *testing.T) {
		requireEncoder(t, "mpeg4")
		in := filepath.Join(t.TempDir(), "v.mp4")
		ffrun(t, "-f", "lavfi", "-i", "testsrc=size=64x64:rate=10:duration=1", "-c:v", "mpeg4", in)
		o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, eng)
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeNoAudio)
		noLeftovers(t, o)
	})
	t.Run("six channels", func(t *testing.T) {
		in := filepath.Join(t.TempDir(), "six.wav")
		ffrun(t, "-f", "lavfi", "-i", "anullsrc=channel_layout=5.1:sample_rate=48000", "-t", "1", "-c:a", "pcm_s16le", in)
		_, err := Run(context.Background(), opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, eng))
		wantCode(t, err, CodeUnsupportedChannels)
	})
	t.Run("below the model's 8 kHz", func(t *testing.T) {
		in := makeMonoWav(t, 4000, 1.0)
		_, err := Run(context.Background(), opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, eng))
		wantCode(t, err, CodeInvalidRequest)
	})
	t.Run("too long", func(t *testing.T) {
		o := opts(t, mono, filepath.Join(t.TempDir(), "o.wav"), 0.85, eng)
		o.MaxSeconds = 0.5
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeTooLong)
	})
	t.Run("not media", func(t *testing.T) {
		in := filepath.Join(t.TempDir(), "x.wav")
		must(t, os.WriteFile(in, []byte("this is not audio"), 0o600))
		_, err := Run(context.Background(), opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, eng))
		wantCode(t, err, CodeInvalidRequest)
	})
	t.Run("missing input", func(t *testing.T) {
		_, err := Run(context.Background(), opts(t, filepath.Join(t.TempDir(), "nope.wav"), filepath.Join(t.TempDir(), "o.wav"), 0.85, eng))
		wantCode(t, err, CodeNotFound)
	})
	t.Run("input is a directory", func(t *testing.T) {
		_, err := Run(context.Background(), opts(t, t.TempDir(), filepath.Join(t.TempDir(), "o.wav"), 0.85, eng))
		wantCode(t, err, CodeInvalidRequest)
	})
	t.Run("output directory missing", func(t *testing.T) {
		_, err := Run(context.Background(), opts(t, mono, filepath.Join(t.TempDir(), "no", "o.wav"), 0.85, eng))
		wantCode(t, err, CodeInvalidRequest)
	})
	t.Run("output is a directory", func(t *testing.T) {
		d := filepath.Join(t.TempDir(), "o.wav")
		must(t, os.Mkdir(d, 0o700))
		o := opts(t, mono, d, 0.85, eng)
		o.Overwrite = true
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeInvalidRequest)
	})
	t.Run("output kind must match the input", func(t *testing.T) {
		_, err := Run(context.Background(), opts(t, mono, filepath.Join(t.TempDir(), "o.mov"), 0.85, eng))
		wantCode(t, err, CodeInvalidRequest)
		requireEncoder(t, "mpeg4")
		vid := makeMp4(t)
		_, err = Run(context.Background(), opts(t, vid, filepath.Join(t.TempDir(), "o.wav"), 0.85, eng))
		wantCode(t, err, CodeInvalidRequest)
	})
	t.Run("bad arguments", func(t *testing.T) {
		out := filepath.Join(t.TempDir(), "o.wav")
		for name, mut := range map[string]func(*Options){
			"wet 1.5":         func(o *Options) { o.Wet = 1.5 },
			"wet -0.1":        func(o *Options) { o.Wet = -0.1 },
			"wet NaN":         func(o *Options) { o.Wet = math.NaN() },
			"stereo left":     func(o *Options) { o.Stereo = "left" },
			"relative in":     func(o *Options) { o.In = "in.wav" },
			"relative out":    func(o *Options) { o.Out = "o.wav" },
			"empty out":       func(o *Options) { o.Out = "" },
			"out extension":   func(o *Options) { o.Out = out + ".txt" },
			"negative length": func(o *Options) { o.MaxSeconds = -1 },
			"relative forbid": func(o *Options) { o.Forbidden = []string{"meetings"} },
		} {
			o := opts(t, mono, out, 0.85, eng)
			mut(&o)
			_, err := Run(context.Background(), o)
			if e, ok := err.(*Error); !ok || e.Code != CodeInvalidRequest {
				t.Errorf("%s: %v", name, err)
			}
		}
	})
	t.Run("engine missing", func(t *testing.T) {
		_, err := Run(context.Background(), opts(t, mono, filepath.Join(t.TempDir(), "o.wav"), 0.85, "/nonexistent/ox-clean"))
		wantCode(t, err, CodeUnavailable)
	})
	t.Run("disk space", func(t *testing.T) {
		old := statFS
		defer func() { statFS = old }()
		statFS = func(string) (uint64, syscall.Fsid, error) { return 1000, syscall.Fsid{}, nil }
		o := opts(t, mono, filepath.Join(t.TempDir(), "o.wav"), 0.85, eng)
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeDiskSpace)
		noLeftovers(t, o)
	})
}

func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	must(t, err)
	return b
}

// The forbidden tree (the daemon passes <Home>/meetings): In and Out are both checked, after resolving symlinks of the
// longest existing prefix, and by file identity.
func TestForbiddenTrees(t *testing.T) {
	requireTools(t)
	eng := fakeEngine(t, "1")
	root, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	forbid := filepath.Join(root, "meetings")
	must(t, os.MkdirAll(filepath.Join(forbid, "m1"), 0o700))
	secret := filepath.Join(forbid, "m1", "mic.wav")
	must(t, os.WriteFile(secret, mustRead(t, makeMonoWav(t, 48000, 1.0)), 0o600))
	before := names(t, filepath.Join(forbid, "m1"))
	elsewhere := filepath.Join(root, "elsewhere")
	must(t, os.Mkdir(elsewhere, 0o700))
	fine := makeMonoWav(t, 48000, 1.0)

	refuse := func(t *testing.T, in, out string) {
		t.Helper()
		o := opts(t, in, out, 0.85, eng)
		o.Forbidden = []string{forbid}
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeForbiddenPath)
		if names(t, filepath.Join(forbid, "m1")) != before {
			t.Fatal("something was written into the forbidden tree")
		}
		noLeftovers(t, o)
	}

	t.Run("input inside", func(t *testing.T) { refuse(t, secret, filepath.Join(elsewhere, "o.wav")) })
	t.Run("output inside", func(t *testing.T) { refuse(t, fine, filepath.Join(forbid, "m1", "o.wav")) })
	t.Run("the tree itself as the output's directory", func(t *testing.T) { refuse(t, fine, filepath.Join(forbid, "o.wav")) })
	t.Run("input through a symlinked file", func(t *testing.T) {
		l := filepath.Join(elsewhere, "innocent.wav")
		must(t, os.Symlink(secret, l))
		refuse(t, l, filepath.Join(elsewhere, "o.wav"))
	})
	// Out does not exist yet, but its parent is a link into the tree: the longest existing prefix is resolved.
	t.Run("output that does not exist, parent is a symlink into the tree", func(t *testing.T) {
		l := filepath.Join(elsewhere, "shortcut")
		must(t, os.Symlink(filepath.Join(forbid, "m1"), l))
		refuse(t, fine, filepath.Join(l, "new.wav"))
	})
	t.Run("the forbidden entry itself is a symlink", func(t *testing.T) {
		alias := filepath.Join(root, "alias")
		must(t, os.Symlink(forbid, alias))
		o := opts(t, secret, filepath.Join(elsewhere, "o2.wav"), 0.85, eng)
		o.Forbidden = []string{alias}
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeForbiddenPath)
	})
	t.Run("another spelling of the same directory", func(t *testing.T) {
		upper := filepath.Join(root, "MEETINGS")
		if _, err := os.Stat(upper); err != nil {
			t.Skip("the volume is case sensitive")
		}
		refuse(t, filepath.Join(upper, "m1", "mic.wav"), filepath.Join(elsewhere, "o3.wav"))
		refuse(t, fine, filepath.Join(upper, "m1", "o.wav"))
	})
	t.Run("a sibling that shares the name prefix is not inside", func(t *testing.T) {
		sib := filepath.Join(root, "meetings-archive")
		must(t, os.Mkdir(sib, 0o700))
		o := opts(t, fine, filepath.Join(sib, "o.wav"), 0.85, eng)
		o.Forbidden = []string{forbid}
		mustRun(t, o)
	})
	t.Run("nothing forbidden, nothing refused", func(t *testing.T) {
		o := opts(t, fine, filepath.Join(elsewhere, "ok.wav"), 0.85, eng)
		o.Forbidden = []string{"", filepath.Join(root, "does-not-exist")}
		mustRun(t, o)
	})
}

// A cancel while the engine runs leaves the output as it was and no part file or scratch behind.
func TestAKilledRunLeavesNoPartFileAndNoOutput(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 48000, 1.0)
	mark := filepath.Join(t.TempDir(), "started")
	slow := writeScript(t, "#!/bin/sh\ntouch '"+mark+"'\nexec sleep 30\n")
	for _, existing := range []bool{false, true} {
		out := filepath.Join(t.TempDir(), "o.wav")
		if existing {
			must(t, os.WriteFile(out, []byte("original"), 0o600))
		}
		_ = os.Remove(mark)
		o := opts(t, in, out, 0.85, slow)
		o.Overwrite = existing
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { _, err := Run(ctx, o); done <- err }()
		waitFor(t, mark)
		cancel()
		select {
		case err := <-done:
			if err != context.Canceled {
				t.Fatalf("existing=%v: err = %v, want context.Canceled", existing, err)
			}
		case <-time.After(20 * time.Second):
			t.Fatal("the run did not end after the cancel")
		}
		if existing {
			if string(mustRead(t, out)) != "original" {
				t.Fatal("the existing output changed")
			}
		} else if _, err := os.Lstat(out); err == nil {
			t.Fatal("an output exists after a cancel")
		}
		noLeftovers(t, o)
	}
}

// The cancel that matters most for user data arrives after the muxer has written the whole file: the result must still
// not appear at Out, and an existing Out must stay as it was.
func TestACancelAfterTheFinalWriteStillLeavesOutUntouched(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 48000, 1.0)
	for _, existing := range []bool{false, true} {
		out := filepath.Join(t.TempDir(), "o.wav")
		if existing {
			must(t, os.WriteFile(out, []byte("original"), 0o600))
		}
		o := opts(t, in, out, 0.85, fakeEngine(t, "1"))
		o.Overwrite = existing
		ctx, cancel := context.WithCancel(context.Background())
		o.Run = func(c context.Context, bin string, args []string) ([]byte, error) {
			b, err := execRunner(c, bin, args)
			if bin == "ffmpeg" && len(args) > 0 && filepath.Dir(args[len(args)-1]) == filepath.Dir(out) {
				cancel() // the final mux finished writing; now the user hits cancel
				return nil, context.Canceled
			}
			return b, err
		}
		_, err := Run(ctx, o)
		if err != context.Canceled {
			t.Fatalf("existing=%v: err = %v", existing, err)
		}
		if existing {
			if string(mustRead(t, out)) != "original" {
				t.Fatal("the existing output was replaced or truncated")
			}
		} else if _, err := os.Lstat(out); err == nil {
			t.Fatal("a half-finished output appeared at Out")
		}
		noLeftovers(t, o)
	}
}

func waitFor(t *testing.T, path string) {
	t.Helper()
	for range 400 {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("%s never appeared", path)
}

func TestAnEngineFailureIsEngineFailedWithABoundedMessageAndNoLeftovers(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 48000, 1.0)
	noisy := writeScript(t, "#!/bin/sh\ni=0; while [ $i -lt 200 ]; do echo \"noise line $i padding padding padding\" >&2; i=$((i+1)); done\necho final words >&2\nexit 3\n")
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, noisy)
	_, err := Run(context.Background(), o)
	wantCode(t, err, CodeEngineFailed)
	e := err.(*Error)
	if !strings.Contains(e.Msg, "final words") || len(e.Msg) > 512+len("the cleanup engine failed: ") {
		t.Errorf("message (%d bytes) %q", len(e.Msg), e.Msg)
	}
	noLeftovers(t, o)
	// an engine that exits 0 without writing anything is a failure too
	silent := writeScript(t, "#!/bin/sh\nexit 0\n")
	o = opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, silent)
	_, err = Run(context.Background(), o)
	wantCode(t, err, CodeEngineFailed)
	noLeftovers(t, o)
}

// Two runs that both finished and reach the final step together: exactly one gets the name, the other is told it
// exists and neither output is torn.
func TestConcurrentRunsToOneOutputNeverClobber(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 48000, 1.0)
	out := filepath.Join(t.TempDir(), "o.wav")
	var barrier sync.WaitGroup
	barrier.Add(2)
	var wg sync.WaitGroup
	errs := make([]error, 2)
	os_ := []Options{opts(t, in, out, 0.85, fakeEngine(t, "1")), opts(t, in, out, 0.85, fakeEngine(t, "1"))}
	for i := range os_ {
		o := os_[i]
		o.Run = func(c context.Context, bin string, args []string) ([]byte, error) {
			b, err := execRunner(c, bin, args)
			if bin == "ffmpeg" && len(args) > 0 && filepath.Dir(args[len(args)-1]) == filepath.Dir(out) && err == nil {
				barrier.Done()
				barrier.Wait()
			}
			return b, err
		}
		wg.Add(1)
		go func() { defer wg.Done(); _, errs[i] = Run(context.Background(), o) }()
	}
	wg.Wait()
	ok := 0
	for _, e := range errs {
		if e == nil {
			ok++
		} else {
			wantCode(t, e, CodeExists)
		}
	}
	if ok != 1 {
		t.Fatalf("%d runs succeeded, want exactly 1 (%v)", ok, errs)
	}
	if d := rmsDiffDB(t, in, out); d > -70 {
		t.Errorf("the output is not a whole clean file: %.1f dB", d)
	}
	for _, o := range os_ {
		noLeftovers(t, o)
	}
}

// A file already sitting at the part file's name is never opened, truncated or removed.
func TestAnExistingFileAtThePartNameIsNeverClobbered(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 48000, 1.0)
	dir := t.TempDir()
	old := partSuffix
	defer func() { partSuffix = old }()
	partSuffix = func() string { return "fixed" }
	squat := filepath.Join(dir, ".voice-clean."+itoa(os.Getpid())+".fixed.part")
	must(t, os.WriteFile(squat, []byte("someone else's file"), 0o600))
	o := opts(t, in, filepath.Join(dir, "o.wav"), 0.85, fakeEngine(t, "1"))
	_, err := Run(context.Background(), o)
	wantCode(t, err, CodeUnavailable)
	if string(mustRead(t, squat)) != "someone else's file" {
		t.Fatal("a file at the part name was clobbered or removed")
	}
	if _, err := os.Lstat(o.Out); err == nil {
		t.Fatal("an output exists")
	}
	if n := names(t, o.TempDir); n != "" {
		t.Errorf("scratch left: %s", n)
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

// What the daemon relies on: the engine runs at nice 15 with the model directory, every ffmpeg call is whitelisted to
// the file protocol, nothing is passed as an option by accident, and the result carries the measurements.
func TestTheEngineRunsNicedAndFFmpegIsLockedToFiles(t *testing.T) {
	requireTools(t)
	in := makeStereoWav(t, 48000, 1.0)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, fakeEngine(t, "1"))
	var mu sync.Mutex
	var calls [][]string
	o.Run = func(c context.Context, bin string, args []string) ([]byte, error) {
		mu.Lock()
		calls = append(calls, append([]string{bin}, args...))
		mu.Unlock()
		return execRunner(c, bin, args)
	}
	r := mustRun(t, o)
	if r.ModelSeconds <= 0 || math.Abs(r.Seconds-1) > 0.05 {
		t.Errorf("result %+v", r)
	}
	engineCalls := 0
	for _, c := range calls {
		switch {
		case c[0] == "/usr/bin/nice":
			engineCalls++
			if c[1] != "-n" || c[2] != "15" || c[3] != o.Engine || c[6] != "--models" || c[7] != "/models" || !strings.HasSuffix(c[4], ".wav") || !strings.HasSuffix(c[5], ".wav") {
				t.Errorf("engine call %v", c)
			}
		case c[0] == "ffmpeg":
			if !contains(c, "-nostdin") {
				t.Errorf("ffmpeg without -nostdin: %v", c)
			}
			// the user's file is only ever opened through the file protocol: a crafted playlist cannot reach the network
			for i, a := range c {
				if a == "-i" && c[i+1] == o.In {
					t.Errorf("the user's file is opened without file: and a whitelist: %v", c)
				}
				if a == "-i" && c[i+1] == "file:"+o.In && (i < 2 || c[i-2] != "-protocol_whitelist" || c[i-1] != "file") {
					t.Errorf("the user's file is opened without a protocol whitelist: %v", c)
				}
			}
		case c[0] == "ffprobe":
			if !contains(c, "-protocol_whitelist") {
				t.Errorf("ffprobe without a protocol whitelist: %v", c)
			}
		}
	}
	if engineCalls != 1 {
		t.Errorf("a stereo mid run must call the engine once, got %d", engineCalls)
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// The output keeps the input's privacy: a 0600 recording does not come back readable by everyone.
func TestTheOutputIsNoMoreReadableThanTheInput(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 48000, 1.0)
	must(t, os.Chmod(in, 0o600))
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, fakeEngine(t, "1"))
	mustRun(t, o)
	st, err := os.Stat(o.Out)
	must(t, err)
	if st.Mode().Perm()&0o077 != 0 {
		t.Errorf("mode %v", st.Mode().Perm())
	}
}
