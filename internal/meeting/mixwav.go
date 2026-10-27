package meeting

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
)

// ErrNoAudio: the meeting has no audio on disk (never recorded, or both channel files are gone or empty).
var ErrNoAudio = errors.New("meeting: no audio")

const (
	wavHeaderSize = 44
	// mixChunkSamples bounds the buffers of one read: a player's request for the rest of an hour never allocates
	// the hour.
	mixChunkSamples = 16 * 1024
	// maxMixSamples is what a WAV size field (32 bits) can describe.
	maxMixSamples = (math.MaxUint32 - (wavHeaderSize - 8)) / bytesPerSample
)

// MixReader is a meeting's two channels as one mono WAV, mixed as it is read: nothing is written to disk. It is an
// io.ReadSeeker and io.ReaderAt (http.ServeContent serves ranges from it); Close releases the channel files.
type MixReader struct {
	*io.SectionReader
	src *mixSource
}

// Size is the length of the WAV in bytes.
func (m *MixReader) Size() int64 { return m.src.size() }

// Close releases the channel files.
func (m *MixReader) Close() error {
	return errors.Join(closeFile(m.src.me), closeFile(m.src.them))
}

func closeFile(f *os.File) error {
	if f == nil {
		return nil
	}
	return f.Close()
}

// OpenMix opens dir's me.pcm and them.pcm as one WAV: 16 kHz, mono, signed 16-bit little-endian. A sample is the sum
// of the two channels' samples, saturated at the 16-bit limits; the shorter channel is padded with silence; a
// missing channel file is a silent channel; a stray last byte (half a sample) is ignored. ErrNoAudio when neither
// channel holds a sample.
func OpenMix(dir string) (*MixReader, error) {
	me, meN, err := openChannel(filepath.Join(dir, MePCM))
	if err != nil {
		return nil, err
	}
	them, themN, err := openChannel(filepath.Join(dir, ThemPCM))
	if err != nil {
		_ = closeFile(me)
		return nil, err
	}
	n := min(max(meN, themN), maxMixSamples)
	if n == 0 {
		_ = closeFile(me)
		_ = closeFile(them)
		return nil, ErrNoAudio
	}
	src := &mixSource{me: me, them: them, meN: meN, themN: themN, n: n}
	return &MixReader{SectionReader: io.NewSectionReader(src, 0, src.size()), src: src}, nil
}

// openChannel opens one channel file and counts its whole samples; a file that is not there is (nil, 0, nil).
func openChannel(path string) (*os.File, int64, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, nil
	}
	if err != nil {
		return nil, 0, fmt.Errorf("meeting: opening audio: %w", err)
	}
	fi, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, 0, fmt.Errorf("meeting: opening audio: %w", err)
	}
	return f, fi.Size() / bytesPerSample, nil
}

// mixSource is the WAV as an io.ReaderAt: the header, then the mixed samples computed from the channel files.
type mixSource struct {
	me, them   *os.File
	meN, themN int64 // whole samples in each file at open
	n          int64 // samples in the mix: the longer channel
}

func (s *mixSource) size() int64 { return wavHeaderSize + s.n*bytesPerSample }

func (s *mixSource) header() [wavHeaderSize]byte {
	var h [wavHeaderSize]byte
	le := binary.LittleEndian
	dataLen := uint32(s.n * bytesPerSample)
	copy(h[0:], "RIFF")
	le.PutUint32(h[4:], wavHeaderSize-8+dataLen)
	copy(h[8:], "WAVEfmt ")
	le.PutUint32(h[16:], 16) // fmt chunk size
	le.PutUint16(h[20:], 1)  // PCM
	le.PutUint16(h[22:], 1)  // mono
	le.PutUint32(h[24:], SampleRate)
	le.PutUint32(h[28:], SampleRate*bytesPerSample)
	le.PutUint16(h[32:], bytesPerSample) // block align
	le.PutUint16(h[34:], 16)             // bits per sample
	copy(h[36:], "data")
	le.PutUint32(h[40:], dataLen)
	return h
}

// ReadAt implements io.ReaderAt over the whole WAV.
func (s *mixSource) ReadAt(p []byte, off int64) (int, error) {
	size := s.size()
	if off < 0 {
		return 0, errors.New("meeting: negative offset")
	}
	if off >= size {
		return 0, io.EOF
	}
	want := len(p)
	n := 0
	if off < wavHeaderSize {
		h := s.header()
		c := copy(p, h[off:])
		n, off, p = c, off+int64(c), p[c:]
	}
	for len(p) > 0 && off < size {
		sample, skip := (off-wavHeaderSize)/bytesPerSample, (off-wavHeaderSize)%bytesPerSample
		count := min(int64(mixChunkSamples), s.n-sample, (int64(len(p))+skip+bytesPerSample-1)/bytesPerSample)
		buf, err := s.mix(sample, count)
		if err != nil {
			return n, err
		}
		c := copy(p, buf[skip:])
		n, off, p = n+c, off+int64(c), p[c:]
	}
	if n < want {
		return n, io.EOF
	}
	return n, nil
}

// mix is count mixed samples from sample on, as little-endian bytes.
func (s *mixSource) mix(sample, count int64) ([]byte, error) {
	a, err := readChannel(s.me, s.meN, sample, count)
	if err != nil {
		return nil, err
	}
	b, err := readChannel(s.them, s.themN, sample, count)
	if err != nil {
		return nil, err
	}
	for i := range count {
		o := i * bytesPerSample
		v := mixSample(int16(binary.LittleEndian.Uint16(a[o:])), int16(binary.LittleEndian.Uint16(b[o:])))
		binary.LittleEndian.PutUint16(a[o:], uint16(v))
	}
	return a, nil
}

// mixSample adds two samples and saturates at the 16-bit limits: two loud voices clip, they do not wrap to the
// opposite sign.
func mixSample(a, b int16) int16 {
	return int16(min(max(int32(a)+int32(b), math.MinInt16), math.MaxInt16))
}

// readChannel is count samples of one channel from sample on as bytes, zero (silence) beyond the channel's end, for a
// missing file, and where the file turns out shorter than it was at open.
func readChannel(f *os.File, have, sample, count int64) ([]byte, error) {
	buf := make([]byte, count*bytesPerSample)
	if f == nil || sample >= have {
		return buf, nil
	}
	avail := min(count, have-sample) * bytesPerSample
	if _, err := f.ReadAt(buf[:avail], sample*bytesPerSample); err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("meeting: reading audio: %w", err)
	}
	return buf, nil
}
