package voiceclean

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
)

// probeInfo is what the run needs to know about the input.
type probeInfo struct {
	AudioIndex  int     // stream index of the first audio stream
	SampleRate  int     // of that stream
	Channels    int     // of that stream
	Seconds     float64 // length of that stream (the container's when the stream does not say)
	HasVideo    bool    // a video stream that is not cover art
	StreamIndex []int   // every stream, in input order
}

type probeDoc struct {
	Streams []struct {
		Index       int    `json:"index"`
		CodecType   string `json:"codec_type"`
		SampleRate  string `json:"sample_rate"`
		Channels    int    `json:"channels"`
		Duration    string `json:"duration"`
		Disposition struct {
			AttachedPic int `json:"attached_pic"`
		} `json:"disposition"`
	} `json:"streams"`
	Format struct {
		Duration string `json:"duration"`
	} `json:"format"`
}

// probeArgs is the ffprobe command line for one input (the script asked for the same fields one by one).
func probeArgs(in string) []string {
	return []string{"-v", "error", "-protocol_whitelist", "file", "-show_streams", "-show_format", "-of", "json", "file:" + in}
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
		p.StreamIndex = append(p.StreamIndex, s.Index)
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
		case "video":
			if s.Disposition.AttachedPic != 1 {
				p.HasVideo = true
			}
		}
	}
	if p.AudioIndex < 0 {
		return nil, errNoAudio
	}
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
