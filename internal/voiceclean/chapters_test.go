package voiceclean

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Issue #480. A QuickTime chapter track is what the mov and mp4 muxers write for chapters: ffprobe reports it as
//
//	codec_type=data codec_name=bin_data codec_tag_string=text handler_name=SubtitleHandler disposition all 0
//
// It is the muxer's rendering of the chapters, not a stream of the recording, so it is never mapped as a stream; the
// chapters themselves travel with -map_chapters and the output muxer writes a track of its own for them.

// makeChapterFixture writes an mkv with picture, audio and two chapters (lavfi sources plus an FFMETADATA file) and
// remuxes it with -c copy -map_chapters 0 into ext (mov or mp4): the muxer writes the chapter text track, as real
// tools do. For ext "mkv" the file is the chaptered source itself (chapters, no track).
func makeChapterFixture(t *testing.T, ext string) string {
	t.Helper()
	requireEncoder(t, "mpeg4")
	dir := t.TempDir()
	meta := filepath.Join(dir, "m.txt")
	must(t, os.WriteFile(meta, []byte(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=one\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=two\n"), 0o600))
	src := filepath.Join(dir, "src.mkv")
	args := append([]string{"-f", "lavfi", "-i", "testsrc=size=160x120:rate=25:duration=2"}, tone(440, 48000, 2)...)
	ffrun(t, append(args, "-i", meta, "-map", "0:v", "-map", "1:a", "-map_chapters", "2", "-c:v", "mpeg4", "-c:a", "aac", src)...)
	if ext == "mkv" {
		return src
	}
	p := filepath.Join(dir, "in."+ext)
	ffrun(t, "-i", src, "-map", "0", "-map_chapters", "0", "-c", "copy", p)
	return p
}

// layoutWithoutChapterTrack is the stream layout (codec names and types; the codec tag is the container's) of a file
// with its chapter track left out. The fixtures carry no other data track.
func layoutWithoutChapterTrack(t *testing.T, path string) string {
	t.Helper()
	var keep []string
	for _, l := range strings.Split(fprobe(t, "-show_entries", "stream=codec_name,codec_type", "-of", "csv=p=0", path), "\n") {
		if l != "bin_data,data" {
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "\n")
}

func chapterTracks(t *testing.T, path string) int {
	t.Helper()
	return strings.Count(fprobe(t, "-show_entries", "stream=codec_type,codec_name,codec_tag_string", "-of", "csv=p=0", path), "bin_data")
}

func TestChapterTrackInputIsCleanedAndKeepsItsLayout(t *testing.T) {
	for _, ext := range []string{"mov", "mp4"} {
		t.Run(ext, func(t *testing.T) {
			in := makeChapterFixture(t, ext)
			if chapterTracks(t, in) != 1 {
				t.Fatalf("fixture has no chapter track:\n%s", streamLayout(t, in))
			}
			o := opts(t, in, filepath.Join(t.TempDir(), "o."+ext), 0.85, fakeEngine(t, "1"))
			r := mustRun(t, o)
			if streamLayout(t, in) != streamLayout(t, o.Out) {
				t.Fatalf("layout changed:\n%s\n--\n%s", streamLayout(t, in), streamLayout(t, o.Out))
			}
			if c := chapters(t, o.Out); c == "" || c != chapters(t, in) {
				t.Fatalf("chapters lost: %q vs %q", chapters(t, in), c)
			}
			if len(r.Dropped) != 0 {
				t.Errorf("the chapter track is rebuilt by the muxer, not dropped: %+v", r.Dropped)
			}
			noLeftovers(t, o)
		})
	}
}

// The rule: the output has a chapter track exactly when it is mov or mp4 and has chapters (the muxer writes it); the
// recording's own streams are the input's, in order.
func TestChapterTrackRuleForInputWithoutOne(t *testing.T) {
	in := makeChapterFixture(t, "mkv")
	for ext, want := range map[string]int{"mp4": 1, "mov": 1, "mkv": 0} {
		o := opts(t, in, filepath.Join(t.TempDir(), "o."+ext), 0.85, fakeEngine(t, "1"))
		r := mustRun(t, o)
		if got := chapterTracks(t, o.Out); got != want {
			t.Errorf(".%s: %d chapter tracks, want %d", ext, got, want)
		}
		if layoutWithoutChapterTrack(t, in) != layoutWithoutChapterTrack(t, o.Out) {
			t.Errorf(".%s: streams changed:\n%s\n--\n%s", ext, layoutWithoutChapterTrack(t, in), layoutWithoutChapterTrack(t, o.Out))
		}
		if c := chapters(t, o.Out); c == "" || c != chapters(t, in) {
			t.Errorf(".%s: chapters lost: %q vs %q", ext, chapters(t, in), c)
		}
		if len(r.Dropped) != 0 {
			t.Errorf(".%s: dropped %+v", ext, r.Dropped)
		}
	}
}

// A data track that is not the chapter track (GoPro telemetry is bin_data too, with the tag gpmd) is still carried.
func TestOtherDataTracksAreNotChapterTracks(t *testing.T) {
	doc := `{"streams":[{"index":0,"codec_type":"video","codec_name":"h264"},{"index":1,"codec_type":"audio","codec_name":"aac","sample_rate":"48000","channels":1,"duration":"2"},
{"index":2,"codec_type":"data","codec_name":"bin_data","codec_tag_string":"gpmd"},{"index":3,"codec_type":"data","codec_name":"bin_data","codec_tag_string":"text"}],"chapters":[{"id":0}],"format":{"duration":"2"}}`
	info, err := parseProbe([]byte(doc))
	must(t, err)
	if info.Streams[2].ChapterTrack || !info.Streams[3].ChapterTrack {
		t.Fatalf("chapter track flags: %+v", info.Streams)
	}
	p, err := planVideo(info, "mov")
	must(t, err)
	got := strings.Join(p.maps, " ")
	if !strings.Contains(got, "0:2") || strings.Contains(got, "0:3") || len(p.dropped) != 0 {
		t.Fatalf("maps %q dropped %+v", got, p.dropped)
	}
}

// A data/text stream in a file that lists no chapters is not a rendering of chapters: it is an ordinary data stream,
// carried into mov and dropped (and listed) from mp4. (ffmpeg cannot write such a file here, so the decision is made
// on probe JSON.)
func TestTextDataTrackWithoutChaptersIsOrdinary(t *testing.T) {
	const streams = `"streams":[{"index":0,"codec_type":"video","codec_name":"h264"},{"index":1,"codec_type":"audio","codec_name":"aac","sample_rate":"48000","channels":1,"duration":"2"},
{"index":2,"codec_type":"data","codec_name":"bin_data","codec_tag_string":"text"}]`
	info, err := parseProbe([]byte(`{` + streams + `,"chapters":[],"format":{"duration":"2"}}`))
	must(t, err)
	if info.Streams[2].ChapterTrack {
		t.Fatal("flagged as a chapter track with no chapters in the file")
	}
	p, err := planVideo(info, "mov")
	must(t, err)
	if !strings.Contains(strings.Join(p.maps, " "), "0:2") {
		t.Errorf("mov: the data track is not carried: %v", p.maps)
	}
	p, err = planVideo(info, "mp4")
	must(t, err)
	if len(p.dropped) != 1 || p.dropped[0].Index != 2 {
		t.Errorf("mp4: want the track dropped and listed, got %+v", p.dropped)
	}
	with, err := parseProbe([]byte(`{` + streams + `,"chapters":[{"id":0}],"format":{"duration":"2"}}`))
	must(t, err)
	if !with.Streams[2].ChapterTrack {
		t.Fatal("not flagged although the file lists chapters")
	}
}

func TestProbeAsksForChapters(t *testing.T) {
	if !strings.Contains(strings.Join(probeArgs("x"), " "), "-show_chapters") {
		t.Fatal("ffprobe is not asked for the chapters")
	}
}
