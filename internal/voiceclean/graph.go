package voiceclean

import (
	"fmt"
	"math"
	"path/filepath"
	"strings"
)

// The filter graphs and per-container settings below are ported line for line from the voice-clean script
// (~/Developer/utilities/voice-clean/voice-clean); each is pinned by a test against the script's own string.

// MixFilter blends the dry source (input 0) with the cleaned track (input 1) at the source's own rate, exactly the
// source length: the cleaned track is padded with silence if it came back short, the dry one sets the duration.
// normalize=0 is the script's: the weights are absolute (wet 0.85 -> 0.15 dry + 0.85 cleaned) whatever amix's default
// does. Measured on ffmpeg 9.0.2: the weights sum to 1, so dropping it does not move the level; it is pinned by a string
// test rather than by a level test.
func MixFilter(sampleRate int, wet float64) string {
	return fmt.Sprintf("[1:a]aresample=%d,apad[e];[0:a]aresample=%d[o];[o][e]amix=inputs=2:weights='%.4f %.4f':normalize=0:duration=first[m]",
		sampleRate, sampleRate, 1-wet, wet)
}

// MidMergeFilter replaces the centre of a stereo source only: out_c = c + (enhanced_mid - mid), so the side signal is
// left as recorded. Inputs: 0 stereo source (c0 c1), 1 mid (c2), 2 enhanced mid (c3).
func MidMergeFilter() string {
	return "[0:a][1:a][2:a]amerge=inputs=3,pan=stereo|c0=c0+c3-c2|c1=c1+c3-c2[o]"
}

// channelsMergeFilter joins two cleaned mono channels back into one stereo track (stereo mode "channels").
func channelsMergeFilter() string {
	return "[0:a][1:a]amerge=inputs=2,pan=stereo|c0=c0|c1=c1[o]"
}

const (
	midPanFilter = "pan=mono|c0=0.5*c0+0.5*c1"
	leftFilter   = "pan=mono|c0=c0"
	rightFilter  = "pan=mono|c0=c1"
)

// Container extensions the cleaned file may have. A video input keeps its picture, so its output must be a video
// container; an audio-only input gets an audio file (or .mp4, which the script wrote as an iPod-style m4a).
// coverExts are the audio containers that take a cover picture as an attached-picture stream.
var coverExts = map[string]bool{"m4a": true, "mp3": true, "flac": true}

var (
	videoExts = map[string]bool{"mov": true, "mp4": true, "m4v": true, "mkv": true, "webm": true}
	audioExts = map[string]bool{"wav": true, "flac": true, "mp3": true, "m4a": true}
)

func extOf(path string) string { return strings.ToLower(strings.TrimPrefix(filepath.Ext(path), ".")) }

// videoMux is the container and the re-encode of the cleaned audio track for a video output, by extension.
func videoMux(ext string) (format string, audio []string) {
	switch ext {
	case "webm":
		return "webm", []string{"-c:a:0", "libopus", "-b:a:0", "160k"}
	case "mkv":
		return "matroska", []string{"-c:a:0", "aac", "-b:a:0", "256k"}
	case "mp4", "m4v":
		return "mp4", []string{"-c:a:0", "aac", "-b:a:0", "256k"}
	default:
		return "mov", []string{"-c:a:0", "aac", "-b:a:0", "256k"}
	}
}

// audioMuxArgs is the encode of the cleaned mix for an audio-only output, by extension; ok is false for an extension
// the script refused.
func audioMuxArgs(ext string) (args []string, ok bool) {
	switch ext {
	case "wav":
		return []string{"-c:a", "pcm_f32le", "-f", "wav"}, true
	case "flac":
		return []string{"-c:a", "flac", "-f", "flac"}, true
	case "mp3":
		return []string{"-c:a", "libmp3lame", "-q:a", "0", "-f", "mp3"}, true
	case "m4a", "mp4":
		return []string{"-c:a", "aac", "-b:a", "256k", "-f", "ipod"}, true
	}
	return nil, false
}

// aacPriming is the AAC encoder's delay in samples (one frame).
const aacPriming = 1024

// audioOffset is where the cleaned track must start on the container's timeline so the lag to the picture stays what
// the input had. The mix file starts at 0; the source's own start (an iPhone clip's audio can begin a second after the
// picture, a late-starting video makes it negative) is put back with -itsoffset.
//
// In mp4, m4v and mov the AAC encoder's priming delay goes into an edit list that starts the stream one frame
// (1024/rate) earlier than asked, so a non-zero start is pushed by that much. Measured on ffmpeg 9.0.2: without it
// the audio of an mp4 or mov came out 0.0213 s (48 kHz) early; a zero start needs nothing; mkv is exact; webm (Opus
// pre-skip is handled by the muxer) lands within 1 ms.
func audioOffset(info *probeInfo, ext string) float64 {
	// ffmpeg moves every stream it copies from the input by minus the file's own start, so the clean track moves with
	// them: it is placed at its start relative to the file's.
	start := info.AudioStart - info.FormatStart
	if math.Abs(start) < 1e-6 {
		return 0
	}
	switch ext {
	case "mp4", "m4v", "mov":
		return start + aacPriming/float64(info.SampleRate)
	}
	return start
}
