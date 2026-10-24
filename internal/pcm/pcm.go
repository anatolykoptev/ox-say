// Package pcm edits 16-bit mono PCM WAV audio: decode, encode, trim
// silence, fade, silence, and a streaming writer for long files.
package pcm

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
)

const (
	fullScale     = 32768.0
	windowSec     = 0.010
	wavHdrBytes   = 44
	riffMin       = 12
	chunkHdrBytes = 8
	fmtPCM        = 1
	bits16        = 16
	bytesPerSamp  = 2
	fmtBodyMin    = 16
	riffSizeOff   = 4
	dataSizeOff   = 40
	dbPerDecade   = 20.0
	chunkAlign    = 2

	// MinRate and MaxRate bound the sample rates Decode accepts; the engine
	// writes 24/48 kHz and ffmpeg anything the producer asks for.
	MinRate = 8000
	MaxRate = 192000
	// MaxBytes bounds a WAV Decode will read (the daemon's engine answer cap).
	MaxBytes = 256 << 20
	// wavUnsized is the data size of a streamed (unfinished) header.
	wavUnsized = 0xFFFFFFFF
)

// Clip is mono 16-bit PCM.
type Clip struct {
	Rate int
	S    []int16
}

// pcmFormat is the parsed fmt chunk.
type pcmFormat struct{ rate int }

// parseFmt accepts exactly PCM s16le mono with a consistent header.
func parseFmt(body []byte) (pcmFormat, error) {
	if len(body) < fmtBodyMin {
		return pcmFormat{}, errors.New("pcm: short fmt chunk")
	}
	format, channels := binary.LittleEndian.Uint16(body), binary.LittleEndian.Uint16(body[2:])
	rate, byteRate := binary.LittleEndian.Uint32(body[4:]), binary.LittleEndian.Uint32(body[8:])
	align, bits := binary.LittleEndian.Uint16(body[12:]), binary.LittleEndian.Uint16(body[14:])
	switch {
	case format != fmtPCM || channels != 1 || bits != bits16:
		return pcmFormat{}, errors.New("pcm: want PCM 16-bit mono")
	case rate < MinRate || rate > MaxRate:
		return pcmFormat{}, fmt.Errorf("pcm: sample rate %d outside %d..%d", rate, MinRate, MaxRate)
	case align != bytesPerSamp || byteRate != rate*bytesPerSamp:
		return pcmFormat{}, errors.New("pcm: inconsistent fmt chunk")
	}
	return pcmFormat{rate: int(rate)}, nil
}

// Decode reads a PCM s16le mono WAV (what audio.cpp and ffmpeg write). It is
// strict: another format, an inconsistent header, a chunk or data run that
// the file does not hold (truncated), an odd data length or a file over
// MaxBytes is an error. A streamed header (data size 0xFFFFFFFF) reads to the
// end of the file.
func Decode(wav []byte) (Clip, error) {
	if len(wav) > MaxBytes {
		return Clip{}, fmt.Errorf("pcm: %d bytes is over the %d byte cap", len(wav), MaxBytes)
	}
	if len(wav) < riffMin || string(wav[:4]) != "RIFF" || string(wav[8:12]) != "WAVE" {
		return Clip{}, errors.New("pcm: not a WAV file")
	}
	var f pcmFormat
	fmtSeen := false
	for off := int64(riffMin); off+chunkHdrBytes <= int64(len(wav)); {
		id, size := string(wav[off:off+4]), int64(binary.LittleEndian.Uint32(wav[off+4:]))
		bodyAt := off + chunkHdrBytes
		rest := int64(len(wav)) - bodyAt
		if id == "data" {
			if !fmtSeen {
				return Clip{}, errors.New("pcm: data before fmt")
			}
			if size == wavUnsized {
				// A stream whose writer never finished: it holds what reached
				// the disk. With nothing in it, it is a crashed file, not an
				// empty recording.
				if rest == 0 {
					return Clip{}, errors.New("pcm: unfinished WAV with no audio")
				}
				size = rest
			}
			return decodeData(f, wav[bodyAt:], size)
		}
		if size > rest {
			return Clip{}, fmt.Errorf("pcm: truncated %q chunk", id)
		}
		if id == "fmt " {
			if fmtSeen {
				return Clip{}, errors.New("pcm: second fmt chunk")
			}
			var err error
			if f, err = parseFmt(wav[bodyAt : bodyAt+size]); err != nil {
				return Clip{}, err
			}
			fmtSeen = true
		}
		off = bodyAt + size + size%chunkAlign
	}
	return Clip{}, errors.New("pcm: no data chunk")
}

func decodeData(f pcmFormat, body []byte, size int64) (Clip, error) {
	switch {
	case size > int64(len(body)):
		return Clip{}, fmt.Errorf("pcm: truncated data chunk (%d of %d bytes)", len(body), size)
	case size%bytesPerSamp != 0:
		return Clip{}, errors.New("pcm: odd data length")
	}
	c := Clip{Rate: f.rate, S: make([]int16, size/bytesPerSamp)}
	for i := range c.S {
		c.S[i] = int16(binary.LittleEndian.Uint16(body[bytesPerSamp*i:]))
	}
	return c, nil
}

// header writes the 44-byte WAV header; riffBytes and dataBytes are the size
// fields (wavUnsized for a stream whose length is not known yet).
func header(w io.Writer, rate int, riffBytes, dataBytes uint32) error {
	var b bytes.Buffer
	b.WriteString("RIFF")
	_ = binary.Write(&b, binary.LittleEndian, riffBytes)
	b.WriteString("WAVEfmt ")
	for _, v := range []any{uint32(fmtBodyMin), uint16(fmtPCM), uint16(1), uint32(rate), uint32(bytesPerSamp * rate), uint16(bytesPerSamp), uint16(bits16)} {
		_ = binary.Write(&b, binary.LittleEndian, v)
	}
	b.WriteString("data")
	_ = binary.Write(&b, binary.LittleEndian, dataBytes)
	_, err := w.Write(b.Bytes())
	return err
}

// Encode writes a canonical 44-byte-header WAV.
func (c Clip) Encode() []byte {
	var b bytes.Buffer
	data := uint32(bytesPerSamp * len(c.S))
	_ = header(&b, c.Rate, uint32(wavHdrBytes-chunkHdrBytes)+data, data)
	_ = binary.Write(&b, binary.LittleEndian, c.S)
	return b.Bytes()
}

// Seconds is the clip's duration (0 for a clip with no rate).
func (c Clip) Seconds() float64 {
	if c.Rate <= 0 {
		return 0
	}
	return float64(len(c.S)) / float64(c.Rate)
}

func (c Clip) window() int { return max(1, int(windowSec*float64(c.Rate))) }

// loud reports per 10 ms window whether its RMS is above floorDB dBFS.
func (c Clip) loud(floorDB float64) []bool {
	w := c.window()
	floor := math.Pow(10, floorDB/dbPerDecade) * fullScale
	out := make([]bool, (len(c.S)+w-1)/w)
	for i := range out {
		seg := c.S[i*w : min(len(c.S), (i+1)*w)]
		sum := 0.0
		for _, s := range seg {
			sum += float64(s) * float64(s)
		}
		out[i] = math.Sqrt(sum/float64(len(seg))) > floor
	}
	return out
}

// Trim cuts leading and trailing windows quieter than floorDB, keeping padSec
// each side; it returns the trimmed clip and the seconds cut at the start.
func (c Clip) Trim(floorDB, padSec float64) (Clip, float64) {
	first, last := -1, -1
	for i, on := range c.loud(floorDB) {
		if on {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 {
		return Clip{Rate: c.Rate}, c.Seconds()
	}
	w, pad := c.window(), int(math.Max(0, padSec)*float64(c.Rate))
	from, to := max(0, first*w-pad), min(len(c.S), (last+1)*w+pad)
	return Clip{Rate: c.Rate, S: c.S[from:to]}, float64(from) / float64(c.Rate)
}

// LongestSilence is the longest quiet run inside the trimmed clip, seconds.
func (c Clip) LongestSilence(floorDB float64) float64 {
	t, _ := c.Trim(floorDB, 0)
	run, best := 0, 0
	for _, on := range t.loud(floorDB) {
		if on {
			run = 0
			continue
		}
		run++
		best = max(best, run)
	}
	return float64(best) * windowSec
}

// Fade returns a copy with linear fade-in and fade-out of sec.
func (c Clip) Fade(sec float64) Clip {
	out := Clip{Rate: c.Rate, S: append([]int16(nil), c.S...)}
	n := min(len(out.S)/2, int(math.Max(0, sec)*float64(c.Rate)))
	for i := 0; i < n; i++ {
		g := float64(i) / float64(n)
		out.S[i] = int16(float64(out.S[i]) * g)
		out.S[len(out.S)-1-i] = int16(float64(out.S[len(out.S)-1-i]) * g)
	}
	return out
}

// Silence is sec of digital silence (none for a negative or NaN sec).
func Silence(rate int, sec float64) Clip {
	n := int(math.Round(sec * float64(rate)))
	return Clip{Rate: rate, S: make([]int16, max(0, n))}
}

// Writer streams clips of one rate into a WAV file; Close patches sizes.
type Writer struct {
	f    *os.File
	buf  *bufio.Writer
	rate int
	n    uint32
}

// NewWriter writes a placeholder header to f. The sizes are wavUnsized until
// Close patches them, so a file that was never closed (a crash) reads as the
// audio that reached the disk, and as an error when none did, never as a
// finished empty WAV.
func NewWriter(f *os.File, rate int) (*Writer, error) {
	if rate < MinRate || rate > MaxRate {
		return nil, fmt.Errorf("pcm: sample rate %d outside %d..%d", rate, MinRate, MaxRate)
	}
	if err := header(f, rate, wavUnsized, wavUnsized); err != nil {
		return nil, err
	}
	return &Writer{f: f, buf: bufio.NewWriter(f), rate: rate}, nil
}

// Write appends c; a different sample rate, or growth past what a WAV header
// can size (4 GiB), is refused.
func (w *Writer) Write(c Clip) error {
	if c.Rate != w.rate {
		return fmt.Errorf("pcm: a %d Hz clip in a %d Hz file", c.Rate, w.rate)
	}
	add := uint64(bytesPerSamp) * uint64(len(c.S))
	if uint64(w.n)+add > math.MaxUint32-wavHdrBytes {
		return errors.New("pcm: file would exceed the 4 GiB WAV limit")
	}
	if err := binary.Write(w.buf, binary.LittleEndian, c.S); err != nil {
		return err
	}
	w.n += uint32(add)
	return nil
}

// Close flushes, patches the RIFF and data sizes, and closes the file.
func (w *Writer) Close() error {
	err := w.buf.Flush()
	for _, p := range []struct {
		off int64
		v   uint32
	}{{riffSizeOff, uint32(wavHdrBytes-chunkHdrBytes) + w.n}, {dataSizeOff, w.n}} {
		if err == nil {
			var b [4]byte
			binary.LittleEndian.PutUint32(b[:], p.v)
			_, err = w.f.WriteAt(b[:], p.off)
		}
	}
	if cerr := w.f.Close(); err == nil {
		err = cerr
	}
	return err
}

// Abort closes the file and removes it: the way out of a failed write. It is
// safe after Close or a second time.
func (w *Writer) Abort() error {
	err := w.f.Close()
	if errors.Is(err, os.ErrClosed) {
		err = nil
	}
	if rerr := os.Remove(w.f.Name()); rerr != nil && !os.IsNotExist(rerr) && err == nil {
		err = rerr
	}
	return err
}

// QuietestWindow returns the start index of the window-sample span with the
// least energy, scanning in steps of half a window; the earliest wins a tie.
// A clip shorter than window returns 0. A caller that must cut audio between
// words cuts at start+window/2.
func (c Clip) QuietestWindow(window int) int {
	if window <= 0 || len(c.S) <= window {
		return 0
	}
	step := max(1, window/2)
	best, bestEnergy := 0, math.MaxFloat64
	for from := 0; from+window <= len(c.S); from += step {
		e := 0.0
		for _, s := range c.S[from : from+window] {
			e += float64(s) * float64(s)
		}
		if e < bestEnergy {
			best, bestEnergy = from, e
		}
	}
	return best
}
