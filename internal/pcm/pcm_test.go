package pcm

import (
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tone(rate int, secs float64) []int16 {
	s := make([]int16, int(secs*float64(rate)))
	for i := range s {
		s[i] = int16(16000 * math.Sin(2*math.Pi*440*float64(i)/float64(rate)))
	}
	return s
}

// Trim cuts silence and reports the lead; Encode/Decode round-trip.
// Mutation: return c unchanged from Trim -> lead 0 -> RED.
func TestTrimAndRoundTrip(t *testing.T) {
	c := Clip{Rate: 48000, S: append(append(make([]int16, 24000), tone(48000, 1)...), make([]int16, 48000)...)}
	got, lead := c.Trim(-45, 0.04)
	if math.Abs(lead-0.46) > 0.011 || math.Abs(got.Seconds()-1.08) > 0.021 {
		t.Fatalf("lead %.3f, len %.3f", lead, got.Seconds())
	}
	round, err := Decode(got.Encode())
	if err != nil || round.Rate != 48000 || len(round.S) != len(got.S) {
		t.Fatalf("round trip %v %d", err, len(round.S))
	}
	for i := range got.S {
		if round.S[i] != got.S[i] {
			t.Fatalf("sample %d: %d != %d", i, round.S[i], got.S[i])
		}
	}
}

// The streaming writer refuses a rate change and patches the header sizes.
// Mutation: drop the rate check in Writer.Write -> RED.
func TestWriterStreams(t *testing.T) {
	p := filepath.Join(t.TempDir(), "o.wav")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	w, err := NewWriter(f, 48000)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Write(Clip{Rate: 48000, S: tone(48000, 0.5)}); err != nil {
		t.Fatal(err)
	}
	if err := w.Write(Silence(48000, 0.25)); err != nil {
		t.Fatal(err)
	}
	if err := w.Write(Clip{Rate: 24000, S: tone(24000, 0.1)}); err == nil {
		t.Fatal("a 24 kHz clip was accepted into a 48 kHz file")
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(p)
	c, err := Decode(raw)
	if err != nil || math.Abs(c.Seconds()-0.75) > 0.001 {
		t.Fatalf("%v %.3f", err, c.Seconds())
	}
}

// A never-closed file (a crash mid-assembly) carries the unsized placeholder,
// so it reads as the audio that reached the disk and an empty one is refused:
// it must never pass for a valid, finished, empty WAV (#149.2).
// Mutation: pcm.go NewWriter, header(f, rate, 0, ...) -> a zero data size
// placeholder -> the empty file decodes and the partial file has no samples -> RED.
func TestWriterCrashedFileIsNotAValidEmptyWAV(t *testing.T) {
	p := filepath.Join(t.TempDir(), "o.wav")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	w, err := NewWriter(f, 48000)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(p)
	if c, err := Decode(raw); err == nil {
		t.Fatalf("a header-only crashed file decoded as a valid WAV of %d samples", len(c.S))
	}
	for _, off := range []int{riffSizeOff, dataSizeOff} {
		if got := binary.LittleEndian.Uint32(raw[off:]); got != wavUnsized {
			t.Errorf("placeholder at %d is %#x, want %#x", off, got, uint32(wavUnsized))
		}
	}
	const secs = 1 // far past bufio's buffer: part of it reaches the disk before the "crash"
	if err := w.Write(Clip{Rate: 48000, S: tone(48000, secs)}); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(p)
	c, err := Decode(raw)
	if err != nil || len(c.S) == 0 || len(c.S) > 48000*secs {
		t.Fatalf("partial file: err %v, %d samples", err, len(c.S))
	}
	_ = w.Abort()
}

// Abort closes and removes the file; Close afterwards is harmless.
// Mutation: drop the os.Remove in Abort -> the file survives -> RED.
func TestWriterAbortRemovesTheFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "o.wav")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	w, err := NewWriter(f, 48000)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Write(Silence(48000, 0.1)); err != nil {
		t.Fatal(err)
	}
	if err := w.Abort(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("aborted file still there: %v", err)
	}
	if err := w.Abort(); err != nil {
		t.Fatalf("second Abort: %v", err)
	}
}

// An inner 2 s gap is found; edges are not counted.
// Mutation: LongestSilence counts the untrimmed clip -> 3 s -> RED.
func TestLongestSilence(t *testing.T) {
	s := append(append(tone(48000, 0.5), make([]int16, 96000)...), tone(48000, 0.5)...)
	c := Clip{Rate: 48000, S: append(append(make([]int16, 48000), s...), make([]int16, 3*48000)...)}
	if g := c.LongestSilence(-45); math.Abs(g-2.0) > 0.02 {
		t.Fatalf("gap %.2f", g)
	}
}

func TestSilenceAndFadeEdges(t *testing.T) {
	if n := len(Silence(48000, -1).S); n != 0 {
		t.Errorf("negative silence has %d samples", n)
	}
	if n := len(Silence(48000, math.NaN()).S); n != 0 {
		t.Errorf("NaN silence has %d samples", n)
	}
	if got := (Clip{}).Seconds(); got != 0 {
		t.Errorf("zero-rate clip is %v s", got)
	}
	f := Clip{Rate: 8000, S: []int16{1000, 1000, 1000, 1000}}.Fade(1)
	if f.S[0] != 0 || f.S[3] != 0 || f.S[1] == 0 && f.S[2] == 0 {
		t.Errorf("fade %v", f.S)
	}
}

// wavBytes builds a WAV with explicit fields so malformed variants are one edit away.
type wavSpec struct {
	format, channels, bits, align uint16
	rate, byteRate                uint32
	dataSize                      uint32 // size field written for the data chunk
	data                          []byte // bytes actually present
	fmtSize                       uint32
	extra                         string // chunk placed before data
}

func goodSpec() wavSpec {
	return wavSpec{format: 1, channels: 1, bits: 16, align: 2, rate: 48000, byteRate: 96000,
		dataSize: 8, data: []byte{1, 0, 2, 0, 3, 0, 4, 0}, fmtSize: 16}
}

func (w wavSpec) bytes() []byte {
	le := binary.LittleEndian
	var b []byte
	b = append(b, "RIFF\x00\x00\x00\x00WAVEfmt "...)
	b = le.AppendUint32(b, w.fmtSize)
	b = le.AppendUint16(b, w.format)
	b = le.AppendUint16(b, w.channels)
	b = le.AppendUint32(b, w.rate)
	b = le.AppendUint32(b, w.byteRate)
	b = le.AppendUint16(b, w.align)
	b = le.AppendUint16(b, w.bits)
	b = append(b, w.extra...)
	b = append(b, "data"...)
	b = le.AppendUint32(b, w.dataSize)
	return append(b, w.data...)
}

// Decode is strict: PCM s16 mono only, a consistent header, bounded sizes,
// no truncation.
// Mutation: drop the format check in parseFmt -> the float case decodes -> RED.
// Mutation: drop the size > len(body) check in decodeData -> the truncated case decodes -> RED.
func TestDecodeStrict(t *testing.T) {
	cases := []struct {
		name string
		edit func(*wavSpec)
		want string // "" = accepted
	}{
		{"good", func(*wavSpec) {}, ""},
		{"float format", func(w *wavSpec) { w.format = 3 }, "PCM 16-bit mono"},
		{"extensible format", func(w *wavSpec) { w.format = 0xFFFE }, "PCM 16-bit mono"},
		{"stereo", func(w *wavSpec) { w.channels = 2 }, "PCM 16-bit mono"},
		{"8 bit", func(w *wavSpec) { w.bits = 8 }, "PCM 16-bit mono"},
		{"24 bit", func(w *wavSpec) { w.bits = 24 }, "PCM 16-bit mono"},
		{"zero rate", func(w *wavSpec) { w.rate, w.byteRate = 0, 0 }, "sample rate"},
		{"huge rate", func(w *wavSpec) { w.rate, w.byteRate = 4_000_000_000, 0 }, "sample rate"},
		{"bad byte rate", func(w *wavSpec) { w.byteRate = 1 }, "inconsistent"},
		{"bad block align", func(w *wavSpec) { w.align = 4 }, "inconsistent"},
		{"short fmt chunk", func(w *wavSpec) { w.fmtSize = 8 }, ""},
		{"truncated data", func(w *wavSpec) { w.dataSize = 100 }, "truncated data"},
		{"odd data length", func(w *wavSpec) { w.dataSize = 7; w.data = w.data[:7] }, "odd data"},
		{"unsized stream", func(w *wavSpec) { w.dataSize = 0xFFFFFFFF }, ""},
		{"unsized stream, odd tail", func(w *wavSpec) { w.dataSize = 0xFFFFFFFF; w.data = w.data[:7] }, "odd data"},
		{"huge extra chunk", func(w *wavSpec) { w.extra = "LIST\xff\xff\xff\x7f" }, "truncated"},
	}
	for _, c := range cases {
		w := goodSpec()
		c.edit(&w)
		got, err := Decode(w.bytes())
		switch {
		case c.name == "short fmt chunk":
			if err == nil {
				t.Errorf("%s: accepted", c.name)
			}
		case c.want == "" && err != nil:
			t.Errorf("%s: %v", c.name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s: err %v, want %q", c.name, err, c.want)
		case c.want == "" && (got.Rate != 48000 || len(got.S) != 4 || got.S[3] != 4):
			t.Errorf("%s: %+v", c.name, got)
		}
	}
}

func TestDecodeRejectsGarbage(t *testing.T) {
	for name, raw := range map[string][]byte{
		"empty":       nil,
		"short":       []byte("RIFF"),
		"not riff":    []byte("OggS\x00\x00\x00\x00WAVEfmt "),
		"no data":     goodSpec().bytes()[:36],
		"cut header":  goodSpec().bytes()[:30],
		"data no fmt": append([]byte("RIFF\x00\x00\x00\x00WAVEdata\x02\x00\x00\x00"), 1, 0),
	} {
		if _, err := Decode(raw); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestDecodeSkipsOddPaddedChunk(t *testing.T) {
	w := goodSpec()
	w.extra = "LIST\x03\x00\x00\x00abc\x00" // odd size + pad byte
	if c, err := Decode(w.bytes()); err != nil || len(c.S) != 4 {
		t.Fatalf("%v %+v", err, c)
	}
}

func TestDecodeCapsSize(t *testing.T) {
	if _, err := Decode(make([]byte, MaxBytes+1)); err == nil {
		t.Fatal("an over-cap file was read")
	}
}

func TestNewWriterRejectsBadRate(t *testing.T) {
	f, err := os.Create(filepath.Join(t.TempDir(), "o.wav"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := NewWriter(f, 0); err == nil {
		t.Fatal("rate 0 accepted")
	}
}
