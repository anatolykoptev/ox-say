package voiceclean

import (
	"fmt"
	"strconv"
)

// DroppedStream is an input stream that the output container cannot carry and that is not audio or video the user
// listens to or watches (timecode and other data tracks, attachments, bitmap subtitles, cover art): it is left out
// of the output and reported here. Audio and video streams are never dropped silently; see CodeUnsupportedStreams.
type DroppedStream struct {
	Index int
	Type  string // ffprobe codec_type
	Codec string // ffprobe codec_name
}

// videoPlan is how every input stream of a video file is carried into the output container.
type videoPlan struct {
	maps    []string // -map arguments, in input order; the replaced audio stream comes from input 1
	meta    []string // -map_metadata:s:<out> 0:s:<in> for every carried stream: tags, language, handler name
	codecs  []string // per-stream codec overrides after -c copy (subtitle conversions)
	dropped []DroppedStream
}

// What each container can hold by stream copy. mov and matroska take any audio or video codec; mp4 and webm are
// narrower, so a stream outside the list is refused up front instead of failing in the middle of the mux.
var (
	mp4Video  = setOf("h264", "hevc", "mpeg4", "mpeg2video", "mpeg1video", "av1", "vp9", "mjpeg", "png", "h263", "jpeg2000")
	mp4Audio  = setOf("aac", "mp3", "mp2", "ac3", "eac3", "alac", "opus", "flac", "amr_nb", "amr_wb")
	webmVideo = setOf("vp8", "vp9", "av1")
	webmAudio = setOf("opus", "vorbis")

	textSubs   = setOf("subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text")
	bitmapSubs = setOf("dvd_subtitle", "hdmv_pgs_subtitle", "dvb_subtitle")
)

func setOf(v ...string) map[string]bool {
	m := make(map[string]bool, len(v))
	for _, s := range v {
		m[s] = true
	}
	return m
}

// carries reports whether the container (by output extension) can hold a stream of this type and codec by copy.
func carries(ext, typ, codec string) bool {
	switch ext {
	case "mp4", "m4v":
		if typ == "video" {
			return mp4Video[codec]
		}
		return mp4Audio[codec]
	case "webm":
		if typ == "video" {
			return webmVideo[codec]
		}
		return webmAudio[codec]
	}
	return true
}

// subtitleCodec is the codec a subtitle stream gets in the container: "copy" when it can travel as it is, a text
// codec the container takes otherwise, "" when it cannot be carried at all (bitmap subtitles into mp4 or webm).
func subtitleCodec(ext, codec string) string {
	switch ext {
	case "mp4", "m4v", "mov":
		if codec == "mov_text" {
			return "copy"
		}
		if textSubs[codec] {
			return "mov_text"
		}
	case "webm":
		if codec == "webvtt" {
			return "copy"
		}
		if textSubs[codec] {
			return "webvtt"
		}
	case "mkv":
		switch {
		case codec == "mov_text" || codec == "text":
			return "srt"
		case textSubs[codec] || bitmapSubs[codec]:
			return "copy"
		}
	}
	return ""
}

// planVideo decides, stream by stream, what the output carries. Audio and video that the container cannot hold are a
// refusal naming the stream; the rest that it cannot hold is dropped and listed.
func planVideo(info *probeInfo, ext string) (*videoPlan, error) {
	p := &videoPlan{}
	var ns, out int // out counts the output streams mapped so far
	for _, s := range info.Streams {
		in := "0:" + strconv.Itoa(s.Index)
		keep := func() {
			p.meta = append(p.meta, "-map_metadata:s:"+strconv.Itoa(out), "0:s:"+strconv.Itoa(s.Index))
			out++
		}
		drop := func() { p.dropped = append(p.dropped, DroppedStream{Index: s.Index, Type: s.Type, Codec: s.Codec}) }
		switch {
		case s.Index == info.AudioIndex:
			p.maps = append(p.maps, "-map", "1:a:0")
			keep()
		case s.Type == "video" && s.AttachedPic:
			if carries(ext, "video", s.Codec) {
				p.maps = append(p.maps, "-map", in)
				keep()
			} else {
				drop() // cover art is not the picture
			}
		case s.Type == "video" || s.Type == "audio":
			if !carries(ext, s.Type, s.Codec) {
				return nil, newErr(CodeUnsupportedStreams, fmt.Sprintf("stream %d (%s, %s) cannot be stored in a .%s file; choose .mkv or .mov for this input", s.Index, s.Type, s.Codec, ext))
			}
			p.maps = append(p.maps, "-map", in)
			keep()
		case s.Type == "subtitle":
			c := subtitleCodec(ext, s.Codec)
			if c == "" {
				drop()
				continue
			}
			p.maps = append(p.maps, "-map", in)
			keep()
			if c != "copy" {
				p.codecs = append(p.codecs, "-c:s:"+strconv.Itoa(ns), c)
			}
			ns++
		case s.Type == "data" && ext == "mov", s.Type == "attachment" && ext == "mkv":
			p.maps = append(p.maps, "-map", in)
			keep()
		default:
			drop()
		}
	}
	return p, nil
}

// outputBytes is what the output file will take on disk, from the target codec and bitrate rather than the input's
// size (an m4a at 64 kbit/s cleaned into .flac is many times larger). Lossless sizes are upper bounds.
func outputBytes(info *probeInfo, ext string, video bool, inSize int64) float64 {
	rate := func(bitsPerSec float64) float64 { return info.Seconds * bitsPerSec / 8 }
	if video { // everything but the audio is stream-copied; the cleaned audio is added
		if ext == "webm" {
			return float64(inSize) + rate(160_000)
		}
		return float64(inSize) + rate(256_000)
	}
	pcm := info.Seconds * float64(info.SampleRate) * float64(info.Channels)
	switch ext {
	case "wav":
		return pcm * 4
	case "flac":
		return pcm * 3
	case "mp3":
		return rate(245_000)
	}
	return rate(256_000)
}
