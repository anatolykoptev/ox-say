package meeting

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A recording killed mid-write (kill -9, a power cut that kept the synced part) is a pair of torn channel files:
// different lengths, and an odd trailing byte on the one that was being written. The daemon must finish it with what
// reached the disk and carry it through to a transcript; nothing before the cut may be lost.
// Mutation: internal/meeting/mixwav.go OpenMix, stop dropping the odd trailing byte (read the file's length as is) ->
// RED (the stray byte breaks the 16-bit framing and the run fails or shifts every sample).
// Mutation: internal/meeting/runner.go finishIfStale, `now.Sub(last) < staleRecording` -> `true` -> RED (never finished).
func TestAKilledRecordingIsFinishedAndTranscribedFromWhatReachedTheDisk(t *testing.T) {
	f := newFixture(t)
	m, dir, err := f.r.Store.Create(Manifest{Labels: Labels{Me: "Anatoly", Them: "Other"}}, t0)
	if err != nil {
		t.Fatal(err)
	}
	// 20 s on the microphone channel plus half a sample, 12 s on the other: the app died between two writes.
	writePCM(t, dir, MePCM, 20, 5000)
	appendBytes(t, filepath.Join(dir, MePCM), []byte{0x88})
	writePCM(t, dir, ThemPCM, 12, 5000)
	cut := t0.Add(21 * time.Second)
	old(t, dir, cut) // the files stopped changing at the kill

	f.r.Recover() // f.now is two hours on: far past staleRecording
	got := f.load(t, m.ID)
	if got.Status != StatusQueued || got.Ended == nil || !got.Ended.Equal(cut) {
		t.Fatalf("manifest = %+v, want queued and ended at the last write", got)
	}
	mix, err := OpenMix(dir)
	if err != nil {
		t.Fatal(err)
	}
	if want := int64(wavHeaderSize + 20*SampleRate*bytesPerSample); mix.Size() != want {
		t.Fatalf("mix is %d bytes, want %d: the longer channel's 20 s whole samples, the stray byte dropped, the 12 s channel padded", mix.Size(), want)
	}
	if err := f.r.Process(context.Background(), m.ID); err != nil {
		t.Fatalf("processing the torn recording: %v", err)
	}
	done := f.load(t, m.ID)
	if done.Status != StatusDone || done.DurationS != 20 {
		t.Fatalf("status %s, duration %v s; want done at the longer channel's 20 s", done.Status, done.DurationS)
	}
	tr, _ := os.ReadFile(filepath.Join(dir, TranscriptMD))
	for _, want := range []string{"**Anatoly**", "**Other**"} {
		if !strings.Contains(string(tr), want) {
			t.Errorf("transcript lacks %q, a channel was lost:\n%s", want, tr)
		}
	}
}

func appendBytes(t *testing.T, path string, b []byte) {
	t.Helper()
	fh, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	if _, err := fh.Write(b); err != nil {
		t.Fatal(err)
	}
}
