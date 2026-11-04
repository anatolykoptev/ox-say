package voiceclean

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
)

// probeInfo is what the run needs to know about the input.
type probeInfo struct {
	AudioIndex  int          // stream index of the first audio stream
	SampleRate  int          // of that stream
	Channels    int          // of that stream
	Seconds     float64      // length of that stream (the container's when the stream does not say)
	HasVideo    bool         // a video stream that is not cover art
	AudioStart  float64      // start_time of that stream in the container's timeline (may be negative or fractional)
	FormatStart float64      // start_time of the whole file: ffmpeg moves every stream it copies by minus this
	VideoStart  float64      // start_time of the first real video stream; 0 when there is none
	Streams     []streamInfo // every stream, in input order
}

// streamInfo is one input stream as far as the muxing plan needs it.
type streamInfo struct {
	Index       int
	Type        string // ffprobe codec_type: video, audio, subtitle, data, attachment
	Codec       string // ffprobe codec_name
	AttachedPic bool   // a video stream that is cover art
	// ChapterTrack is a QuickTime chapter track: ffprobe shows it as codec_type data, codec bin_data, tag "text"
	// (handler SubtitleHandler, no disposition), in a file that also lists chapters. It is the mov/mp4 muxer's
	// rendering of the chapters, so it is never mapped as a stream; -map_chapters carries the chapters and the output
	// muxer writes a track for them. Other data tracks are bin_data too (GoPro telemetry is tagged gpmd), so the tag
	// decides, not the codec; and a text data track in a file with no chapters is nobody's rendering of anything, so
	// it is an ordinary data stream (carried where the container allows, else dropped and listed).
	ChapterTrack bool
}

type probeDoc struct {
	Streams []struct {
		Index       int    `json:"index"`
		CodecType   string `json:"codec_type"`
		CodecName   string `json:"codec_name"`
		CodecTag    string `json:"codec_tag_string"`
		StartTime   string `json:"start_time"`
		SampleRate  string `json:"sample_rate"`
		Channels    int    `json:"channels"`
		Duration    string `json:"duration"`
		Disposition struct {
			AttachedPic int `json:"attached_pic"`
		} `json:"disposition"`
	} `json:"streams"`
	Chapters []json.RawMessage `json:"chapters"`
	Format   struct {
		Duration  string `json:"duration"`
		StartTime string `json:"start_time"`
	} `json:"format"`
}

// probeArgs is the ffprobe command line for one input (the script asked for the same fields one by one).
func probeArgs(in string) []string {
	return []string{"-v", "error", "-protocol_whitelist", "file", "-show_streams", "-show_format", "-show_chapters", "-of", "json", "file:" + in}
}

// parseProbe reads ffprobe's JSON. A missing audio stream is the sentinel errNoAudio; anything unusable about the
// audio stream is a plain error (the caller says invalid_request).
func parseProbe(raw []byte) (*probeInfo, error) {
	var doc probeDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("ffprobe output is not JSON: %w", err)
	}
	p := &probeInfo{AudioIndex: -1}
	for _, s := range doc.Streams {
		p.Streams = append(p.Streams, streamInfo{Index: s.Index, Type: s.CodecType, Codec: codecLabel(s.CodecName, s.CodecTag),
			AttachedPic:  s.CodecType == "video" && s.Disposition.AttachedPic == 1,
			ChapterTrack: len(doc.Chapters) > 0 && s.CodecType == "data" && s.CodecTag == "text"})
		switch s.CodecType {
		case "audio":
			if p.AudioIndex >= 0 {
				continue
			}
			p.AudioIndex = s.Index
			p.Channels = s.Channels
			sr, err := strconv.Atoi(s.SampleRate)
			if err != nil || sr <= 0 {
				return nil, fmt.Errorf("audio stream %d has no usable sample rate (%q)", s.Index, s.SampleRate)
			}
			p.SampleRate = sr
			p.Seconds = parseSeconds(s.Duration)
			p.AudioStart = parseSigned(s.StartTime)
		case "video":
			if s.Disposition.AttachedPic != 1 {
				if !p.HasVideo {
					p.VideoStart = parseSigned(s.StartTime)
				}
				p.HasVideo = true
			}
		}
	}
	if p.AudioIndex < 0 {
		return nil, errNoAudio
	}
	p.FormatStart = parseSigned(doc.Format.StartTime)
	if p.Seconds <= 0 {
		p.Seconds = parseSeconds(doc.Format.Duration)
	}
	return p, nil
}

var errNoAudio = fmt.Errorf("no audio stream")

// parseSeconds reads ffprobe's decimal seconds; "N/A", empty and non-finite values are 0.
func parseSeconds(s string) float64 {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
		return 0
	}
	return v
}

// parseSigned reads a start time: it may be negative (an edit list that begins before zero); "N/A", empty and
// non-finite values are 0.
func parseSigned(s string) float64 {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0
	}
	return v
}

// codecLabel is the codec's name, or its four-character tag when ffprobe has no name for it (a timecode track is
// "unknown" with the tag "tmcd").
func codecLabel(name, tag string) string {
	if (name == "" || name == "unknown") && tag != "" && !strings.HasPrefix(tag, "[0]") {
		return tag
	}
	if name == "" {
		return "unknown"
	}
	return name
}
