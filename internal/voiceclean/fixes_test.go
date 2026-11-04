package voiceclean

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
)

// ---- hard links into a forbidden tree ---------------------------------------------------------------------------

func TestAHardLinkToAForbiddenFileIsForbidden(t *testing.T) {
	requireTools(t)
	eng := fakeEngine(t, "1")
	root, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	forbid := filepath.Join(root, "meetings")
	must(t, os.MkdirAll(filepath.Join(forbid, "m1", "deeper"), 0o700))
	secret := filepath.Join(forbid, "m1", "deeper", "mic.wav")
	must(t, os.WriteFile(secret, mustRead(t, makeMonoWav(t, 48000, 1.0)), 0o600))
	elsewhere := filepath.Join(root, "elsewhere")
	must(t, os.Mkdir(elsewhere, 0o700))
	hl := filepath.Join(elsewhere, "hl.wav")
	must(t, os.Link(secret, hl))

	t.Run("input is a hard link of a meeting file", func(t *testing.T) {
		o := opts(t, hl, filepath.Join(elsewhere, "o.wav"), 0.85, eng)
		o.Forbidden = []string{forbid}
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeForbiddenPath)
		noLeftovers(t, o)
	})
	t.Run("an existing output that is a hard link of a meeting file", func(t *testing.T) {
		out := filepath.Join(elsewhere, "out-hl.wav")
		must(t, os.Link(secret, out))
		o := opts(t, makeMonoWav(t, 48000, 1.0), out, 0.85, eng)
		o.Overwrite = true
		o.Forbidden = []string{forbid}
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeForbiddenPath)
	})
	t.Run("a hard link between two ordinary files is fine", func(t *testing.T) {
		a := filepath.Join(elsewhere, "a.wav")
		must(t, os.WriteFile(a, mustRead(t, makeMonoWav(t, 48000, 1.0)), 0o600))
		b := filepath.Join(elsewhere, "b.wav")
		must(t, os.Link(a, b))
		o := opts(t, b, filepath.Join(elsewhere, "ok.wav"), 0.85, eng)
		o.Forbidden = []string{forbid}
		mustRun(t, o)
	})
	t.Run("a tree too big to search is refused, not guessed", func(t *testing.T) {
		old := maxWalk
		defer func() { maxWalk = old }()
		maxWalk = 2
		a := filepath.Join(elsewhere, "c.wav")
		must(t, os.WriteFile(a, mustRead(t, makeMonoWav(t, 48000, 1.0)), 0o600))
		must(t, os.Link(a, filepath.Join(elsewhere, "d.wav")))
		o := opts(t, a, filepath.Join(elsewhere, "ok2.wav"), 0.85, eng)
		o.Forbidden = []string{forbid}
		_, err := Run(context.Background(), o)
		wantCode(t, err, CodeForbiddenPath)
	})
}

// ---- disk preflight --------------------------------------------------------------------------------------------------

func stubFS(t *testing.T, scratchDir string, scratchFree, outFree uint64) {
	t.Helper()
	old := statFS
	t.Cleanup(func() { statFS = old })
	statFS = func(p string) (uint64, string, error) {
		if p == scratchDir {
			return scratchFree, "scratch-volume", nil
		}
		return outFree, "output-volume", nil
	}
}

// A 64 kbit/s m4a is small; the same audio as flac is not. The output is sized from the target codec.
func TestTheOutputIsSizedFromTheTargetCodecNotTheInput(t *testing.T) {
	requireEncoder(t, "aac")
	in := filepath.Join(t.TempDir(), "in.m4a")
	ffrun(t, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=6", "-ac", "1", "-c:a", "aac", "-b:a", "64k", in)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.flac"), 0.85, fakeEngine(t, "1"))
	stubFS(t, o.TempDir, 1<<40, 3<<19) // 1.5 MiB for the output: enough for the 48 KB input, not for 6 s of flac
	_, err := Run(context.Background(), o)
	wantCode(t, err, CodeDiskSpace)
	noLeftovers(t, o)
}

func TestScratchIsSizedAtTheSourceRateWhenItIsAbove48k(t *testing.T) {
	requireTools(t)
	in := makeMonoWav(t, 96000, 2.0)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.wav"), 0.85, fakeEngine(t, "1"))
	stubFS(t, o.TempDir, 3_000_000, 1<<40) // 2 s at 48 kHz needs 2.3 MB, at 96 kHz 4.6 MB
	_, err := Run(context.Background(), o)
	wantCode(t, err, CodeDiskSpace)
}

func TestOutputBytesByTargetCodec(t *testing.T) {
	info := &probeInfo{Seconds: 10, SampleRate: 44100, Channels: 2}
	for ext, want := range map[string]float64{
		"wav": 10 * 44100 * 2 * 4, "flac": 10 * 44100 * 2 * 3, "mp3": 10 * 245000 / 8.0, "m4a": 10 * 256000 / 8.0,
	} {
		if got := outputBytes(info, ext, false, 5); math.Abs(got-want) > 1 {
			t.Errorf("%s: %v want %v", ext, got, want)
		}
	}
	if got := outputBytes(info, "mp4", true, 1000); math.Abs(got-(1000+10*256000/8.0)) > 1 {
		t.Errorf("video: %v", got)
	}
}

// ---- tags, cover art, stream metadata --------------------------------------------------------------------------------

func TestAudioOutputsKeepTagsAndCoverArt(t *testing.T) {
	requireTools(t)
	cover := filepath.Join(t.TempDir(), "cover.jpg")
	ffrun(t, "-f", "lavfi", "-i", "color=c=red:s=64x64:d=1", "-frames:v", "1", cover)
	for _, c := range []struct{ ext, enc string }{{"m4a", "aac"}, {"mp3", "libmp3lame"}, {"flac", "flac"}} {
		t.Run(c.ext, func(t *testing.T) {
			requireEncoder(t, c.enc)
			in := filepath.Join(t.TempDir(), "in."+c.ext)
			ffrun(t, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1.5", "-i", cover,
				"-map", "0:a", "-map", "1:v", "-c:a", c.enc, "-c:v", "copy", "-disposition:v", "attached_pic",
				"-metadata", "title=Fixture title", "-metadata", "artist=Fixture artist", in)
			if got := fprobe(t, "-show_entries", "stream=codec_type:stream_disposition=attached_pic", "-of", "csv=p=0", in); !strings.Contains(got, "video,1") {
				t.Fatalf("fixture has no cover: %q", got)
			}
			o := opts(t, in, filepath.Join(t.TempDir(), "o."+c.ext), 0.85, fakeEngine(t, "1"))
			mustRun(t, o)
			if got := tag(t, o.Out, "title"); got != "Fixture title" {
				t.Errorf("title %q", got)
			}
			if got := tag(t, o.Out, "artist"); got != "Fixture artist" {
				t.Errorf("artist %q", got)
			}
			if got := fprobe(t, "-show_entries", "stream=codec_type:stream_disposition=attached_pic", "-of", "csv=p=0", o.Out); !strings.Contains(got, "video,1") {
				t.Errorf("cover art lost: %q", got)
			}
			if md5Of(t, in, "-map", "0:v") != md5Of(t, o.Out, "-map", "0:v") {
				t.Error("cover picture changed")
			}
		})
	}
}

func TestVideoKeepsTheReplacedAudioStreamsLanguage(t *testing.T) {
	requireEncoder(t, "mpeg4")
	in := filepath.Join(t.TempDir(), "in.mp4")
	args := []string{"-f", "lavfi", "-i", "testsrc=size=64x64:rate=10:duration=1"}
	args = append(args, tone(440, 48000, 1)...)
	args = append(args, tone(880, 48000, 1)...)
	ffrun(t, append(args, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "mpeg4", "-c:a", "aac",
		"-metadata:s:a:0", "language=fra", "-metadata:s:a:1", "language=deu", in)...)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, fakeEngine(t, "1"))
	mustRun(t, o)
	for sel, want := range map[string]string{"a:0": "fra", "a:1": "deu"} {
		if got := fprobe(t, "-select_streams", sel, "-show_entries", "stream_tags=language", "-of", "csv=p=0", o.Out); got != want {
			t.Errorf("%s language %q, want %q", sel, got, want)
		}
	}
}

// ---- streams the target container cannot carry ----------------------------------------------------------------------

func TestTimecodeTrackIsDroppedAndListedWhenGoingToMp4(t *testing.T) {
	requireEncoder(t, "mpeg4")
	in := filepath.Join(t.TempDir(), "iphone.mov")
	ffrun(t, "-f", "lavfi", "-i", "testsrc=size=64x64:rate=25:duration=1.5", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1.5",
		"-c:v", "mpeg4", "-c:a", "aac", "-timecode", "01:00:00:00", in)
	if got := fprobe(t, "-show_entries", "stream=codec_type,codec_tag_string", "-of", "csv=p=0", in); !strings.Contains(got, "tmcd") {
		t.Fatalf("fixture has no tmcd track: %q", got)
	}
	o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, fakeEngine(t, "1"))
	r := mustRun(t, o)
	if len(r.Dropped) != 1 || r.Dropped[0].Codec != "tmcd" || r.Dropped[0].Type != "data" {
		t.Fatalf("dropped %+v", r.Dropped)
	}
	// the mp4 muxer writes its own timecode track from the picture's timecode tag, which is kept
	if got := fprobe(t, "-select_streams", "v:0", "-show_entries", "stream_tags=timecode", "-of", "csv=p=0", o.Out); got != "01:00:00:00" {
		t.Errorf("timecode %q", got)
	}
	if md5Of(t, in, "-map", "0:v") != md5Of(t, o.Out, "-map", "0:v") {
		t.Error("picture changed")
	}
	noLeftovers(t, o)
	// into a mov nothing is dropped
	o2 := opts(t, in, filepath.Join(t.TempDir(), "o.mov"), 0.85, fakeEngine(t, "1"))
	if r := mustRun(t, o2); len(r.Dropped) != 0 {
		t.Errorf("mov dropped %+v", r.Dropped)
	}
}

func TestSrtSubtitlesAreConvertedForTheTargetContainer(t *testing.T) {
	requireEncoder(t, "mpeg4")
	dir := t.TempDir()
	srt := filepath.Join(dir, "s.srt")
	must(t, os.WriteFile(srt, []byte("1\n00:00:00,000 --> 00:00:01,000\nhello there\n"), 0o600))
	in := filepath.Join(dir, "in.mkv")
	ffrun(t, "-f", "lavfi", "-i", "testsrc=size=64x64:rate=25:duration=1.5", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1.5",
		"-i", srt, "-c:v", "mpeg4", "-c:a", "aac", "-c:s", "srt", in)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, fakeEngine(t, "1"))
	r := mustRun(t, o)
	if len(r.Dropped) != 0 {
		t.Errorf("dropped %+v", r.Dropped)
	}
	if got := fprobe(t, "-select_streams", "s:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", o.Out); got != "mov_text" {
		t.Errorf("subtitle codec %q, want mov_text", got)
	}
	if text := ffText(t, o.Out); !strings.Contains(text, "hello there") {
		t.Errorf("subtitle text lost: %q", text)
	}
}

func TestSrtBecomesWebvttInWebm(t *testing.T) {
	requireEncoder(t, "libvpx")
	requireEncoder(t, "libopus")
	dir := t.TempDir()
	srt := filepath.Join(dir, "s.srt")
	must(t, os.WriteFile(srt, []byte("1\n00:00:00,000 --> 00:00:01,000\nhello there\n"), 0o600))
	in := filepath.Join(dir, "in.mkv")
	ffrun(t, "-f", "lavfi", "-i", "testsrc=size=64x64:rate=25:duration=1.5", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1.5",
		"-i", srt, "-c:v", "libvpx", "-c:a", "libopus", "-c:s", "srt", in)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.webm"), 0.85, fakeEngine(t, "1"))
	mustRun(t, o)
	if got := fprobe(t, "-select_streams", "s:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", o.Out); got != "webvtt" {
		t.Errorf("subtitle codec %q, want webvtt", got)
	}
}

func ffText(t *testing.T, path string) string {
	t.Helper()
	out, err := execRunner(context.Background(), "ffmpeg", []string{"-nostdin", "-v", "error", "-i", path, "-map", "0:s:0", "-f", "srt", "-"})
	must(t, err)
	return string(out)
}

// Video the container cannot hold is a refusal that names the stream, before the engine is started.
func TestVideoThatTheContainerCannotHoldIsRefusedByName(t *testing.T) {
	requireEncoder(t, "mpeg4")
	in := filepath.Join(t.TempDir(), "in.mkv")
	ffrun(t, "-f", "lavfi", "-i", "testsrc=size=64x64:rate=25:duration=1", "-f", "lavfi", "-i", "sine=duration=1", "-c:v", "mpeg4", "-c:a", "aac", in)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.webm"), 0.85, fakeEngine(t, "1"))
	engineStarted := false
	o.Run = func(c context.Context, bin string, args []string) ([]byte, error) {
		if bin == "/usr/bin/nice" {
			engineStarted = true
		}
		return execRunner(c, bin, args)
	}
	_, err := Run(context.Background(), o)
	wantCode(t, err, CodeUnsupportedStreams)
	if m := err.(*Error).Msg; !strings.Contains(m, "stream 0") || !strings.Contains(m, "mpeg4") {
		t.Errorf("message does not name the stream: %q", m)
	}
	if err.(*Error).Status != 422 {
		t.Errorf("status %d", err.(*Error).Status)
	}
	if engineStarted {
		t.Error("the engine ran before the refusal")
	}
	noLeftovers(t, o)
}

func TestPlanVideoTable(t *testing.T) {
	info := &probeInfo{AudioIndex: 1, Streams: []streamInfo{
		{Index: 0, Type: "video", Codec: "h264"}, {Index: 1, Type: "audio", Codec: "aac"},
		{Index: 2, Type: "audio", Codec: "pcm_s16le"}, {Index: 3, Type: "subtitle", Codec: "hdmv_pgs_subtitle"},
		{Index: 4, Type: "video", Codec: "mjpeg", AttachedPic: true}, {Index: 5, Type: "attachment", Codec: "ttf"},
	}}
	if _, err := planVideo(info, "mp4"); err == nil || err.(*Error).Code != CodeUnsupportedStreams || !strings.Contains(err.Error(), "pcm_s16le") {
		t.Fatalf("pcm audio into mp4: %v", err)
	}
	info.Streams = append(info.Streams[:2], info.Streams[3:]...) // without the pcm track
	p, err := planVideo(info, "mp4")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.dropped) != 2 || p.dropped[0].Codec != "hdmv_pgs_subtitle" || p.dropped[1].Codec != "ttf" {
		t.Errorf("dropped %+v", p.dropped)
	}
	if p2, err := planVideo(info, "mkv"); err != nil || len(p2.dropped) != 0 {
		t.Errorf("mkv: %+v %v", p2, err)
	}
}

// ---- the no-hard-link fallback ------------------------------------------------------------------------------------------

func noHardLinks(t *testing.T) {
	t.Helper()
	old := linkFile
	t.Cleanup(func() { linkFile = old })
	linkFile = func(string, string) error { return &os.LinkError{Op: "link", Err: syscall.EPERM} }
}

// On a volume without hard links, an output created between the check and the move is still not replaced.
func TestTheFallbackNeverReplacesAnOutputCreatedAtTheLastMoment(t *testing.T) {
	requireTools(t)
	noHardLinks(t)
	in := makeMonoWav(t, 48000, 1.0)
	out := filepath.Join(t.TempDir(), "o.wav")
	old := afterPublishCheck
	defer func() { afterPublishCheck = old }()
	afterPublishCheck = func() { must(t, os.WriteFile(out, []byte("someone else's"), 0o600)) }
	o := opts(t, in, out, 0.85, fakeEngine(t, "1"))
	_, err := Run(context.Background(), o)
	wantCode(t, err, CodeExists)
	if string(mustRead(t, out)) != "someone else's" {
		t.Fatal("the output created at the last moment was replaced")
	}
	noLeftovers(t, o)
}

func TestConcurrentRunsWithoutHardLinksNeverClobber(t *testing.T) {
	requireTools(t)
	noHardLinks(t)
	in := makeMonoWav(t, 48000, 1.0)
	out := filepath.Join(t.TempDir(), "o.wav")
	var barrier, wg sync.WaitGroup
	barrier.Add(2)
	errs := make([]error, 2)
	for i := range errs {
		o := opts(t, in, out, 0.85, fakeEngine(t, "1"))
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
}

// Without cover art nothing else ties the output to the input's file, so the tags must be asked for.
func TestTagsSurviveWithoutCoverArt(t *testing.T) {
	requireTools(t)
	in := filepath.Join(t.TempDir(), "in.wav")
	ffrun(t, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1", "-metadata", "title=Plain title", "-c:a", "pcm_s16le", in)
	if tag(t, in, "title") != "Plain title" {
		t.Fatal("fixture has no title")
	}
	for _, ext := range []string{"flac", "m4a"} {
		o := opts(t, in, filepath.Join(t.TempDir(), "o."+ext), 0.85, fakeEngine(t, "1"))
		mustRun(t, o)
		if got := tag(t, o.Out, "title"); got != "Plain title" {
			t.Errorf("%s: title %q", ext, got)
		}
	}
}
