package meeting

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"testing"
)

func writeSamples(t *testing.T, dir, name string, s []int16) {
	t.Helper()
	var b bytes.Buffer
	_ = binary.Write(&b, binary.LittleEndian, s)
	if err := os.WriteFile(filepath.Join(dir, name), b.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readAllMix(t *testing.T, dir string) []byte {
	t.Helper()
	m, err := OpenMix(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = m.Close() }()
	raw, err := io.ReadAll(m)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func samplesOf(raw []byte) []int16 {
	out := make([]int16, (len(raw)-44)/2)
	for i := range out {
		out[i] = int16(binary.LittleEndian.Uint16(raw[44+2*i:]))
	}
	return out
}

// The WAV header is the one a player needs: mono, 16 kHz, 16 bit, sizes of the mix.
func TestMixHeader(t *testing.T) {
	dir := t.TempDir()
	writeSamples(t, dir, MePCM, []int16{1, 2, 3})
	writeSamples(t, dir, ThemPCM, []int16{1})
	raw := readAllMix(t, dir)
	if len(raw) != 44+3*2 {
		t.Fatalf("len = %d", len(raw))
	}
	le := binary.LittleEndian
	if string(raw[0:4]) != "RIFF" || le.Uint32(raw[4:]) != 36+6 || string(raw[8:16]) != "WAVEfmt " ||
		le.Uint32(raw[16:]) != 16 || le.Uint16(raw[20:]) != 1 || le.Uint16(raw[22:]) != 1 ||
		le.Uint32(raw[24:]) != SampleRate || le.Uint32(raw[28:]) != SampleRate*2 || le.Uint16(raw[32:]) != 2 ||
		le.Uint16(raw[34:]) != 16 || string(raw[36:40]) != "data" || le.Uint32(raw[40:]) != 6 {
		t.Fatalf("header = % x", raw[:44])
	}
}

// Loud speech on both channels adds up and saturates at the int16 limits; it never wraps to the other sign.
// Mutation: internal/meeting/mixwav.go mixSample, drop the clamp (return int16(a+b)) -> RED.
func TestMixSaturatesInsteadOfWrapping(t *testing.T) {
	dir := t.TempDir()
	writeSamples(t, dir, MePCM, []int16{30000, -30000, 100, math.MaxInt16, math.MinInt16})
	writeSamples(t, dir, ThemPCM, []int16{30000, -30000, -250, 1, -1})
	got := samplesOf(readAllMix(t, dir))
	want := []int16{math.MaxInt16, math.MinInt16, -150, math.MaxInt16, math.MinInt16}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("sample %d = %d, want %d", i, got[i], want[i])
		}
	}
}

// The shorter channel is padded with silence; a missing channel file is a silent channel; an odd trailing byte is
// dropped; no usable file is ErrNoAudio.
func TestMixPadsMissingAndOddChannels(t *testing.T) {
	dir := t.TempDir()
	writeSamples(t, dir, MePCM, []int16{5, 6})
	writeSamples(t, dir, ThemPCM, []int16{1, 1, 1, 1})
	if got := samplesOf(readAllMix(t, dir)); len(got) != 4 || got[0] != 6 || got[1] != 7 || got[2] != 1 || got[3] != 1 {
		t.Errorf("padded mix = %v", got)
	}
	_ = os.Remove(filepath.Join(dir, MePCM))
	if got := samplesOf(readAllMix(t, dir)); len(got) != 4 || got[0] != 1 {
		t.Errorf("without me.pcm = %v", got)
	}
	// 5 bytes: two samples and a stray byte
	odd := t.TempDir()
	if err := os.WriteFile(filepath.Join(odd, MePCM), []byte{1, 0, 2, 0, 0xFF}, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := samplesOf(readAllMix(t, odd)); len(got) != 2 || got[0] != 1 || got[1] != 2 {
		t.Errorf("odd file = %v", got)
	}
	if _, err := OpenMix(t.TempDir()); !errors.Is(err, ErrNoAudio) {
		t.Errorf("no files: %v", err)
	}
	empty := t.TempDir()
	writeSamples(t, empty, MePCM, nil)
	if _, err := OpenMix(empty); !errors.Is(err, ErrNoAudio) {
		t.Errorf("empty file: %v", err)
	}
}

// Reads at any offset, odd ones included, and across the internal chunk size, give the bytes of the whole.
func TestMixReadAtAnyOffset(t *testing.T) {
	dir := t.TempDir()
	n := 100_000 // more than one internal chunk
	me, them := make([]int16, n), make([]int16, n-777)
	for i := range me {
		me[i] = int16(i % 20000)
	}
	for i := range them {
		them[i] = int16(-(i % 9000))
	}
	writeSamples(t, dir, MePCM, me)
	writeSamples(t, dir, ThemPCM, them)
	whole := readAllMix(t, dir)
	m, err := OpenMix(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = m.Close() }()
	for _, c := range []struct{ off, n int }{{0, 10}, {43, 5}, {45, 1}, {131_071, 9}, {len(whole) - 3, 3}, {44 + 65_535, 70_001}} {
		buf := make([]byte, c.n)
		if _, err := m.ReadAt(buf, int64(c.off)); err != nil && err != io.EOF {
			t.Fatal(err)
		}
		if !bytes.Equal(buf, whole[c.off:c.off+c.n]) {
			t.Errorf("ReadAt(%d, %d) differs from the whole", c.off, c.n)
		}
	}
	got := samplesOf(whole)
	for i := 0; i < len(them); i += 997 {
		want := int32(me[i]) + int32(them[i])
		if int32(got[i]) != want {
			t.Fatalf("sample %d = %d, want %d", i, got[i], want)
		}
	}
}
