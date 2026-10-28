package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

const (
	assembleID   = "20261015-120000-a1b2c3"
	fixtureLead  = 0.5 // seconds of silence before and after the tone in a fixture take
	timeSlackSec = 0.03
)

// fixtureTake is lead + 1 s of tone + lead at rate; trimmed it is 1.08 s.
func fixtureTake(rate int) pcm.Clip {
	lead := make([]int16, int(fixtureLead*float64(rate)))
	tone := toneClip(1, 0).S
	if rate != 48000 {
		tone = tone[:rate]
	}
	return pcm.Clip{Rate: rate, S: append(append(append([]int16{}, lead...), tone...), lead...)}
}

// writeTake stores a take and its sidecar under key, the way the taker does.
func writeTake(t *testing.T, dir, key string, clip pcm.Clip, text string) vproject.TakeRef {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, vproject.TakesDir, key+".wav"), clip.Encode(), 0o600); err != nil {
		t.Fatal(err)
	}
	var heard []voices.Word
	ws := strings.Fields(text)
	for j, w := range ws {
		heard = append(heard, voices.Word{W: w, S: fixtureLead + float64(j)/float64(len(ws)), E: fixtureLead + float64(j+1)/float64(len(ws))})
	}
	ref := vproject.TakeRef{Key: key, Passed: true, DurationS: clip.Seconds()}
	writeDetailT(t, filepath.Join(dir, vproject.TakesDir, key+".json"), takeDetail{Ref: ref, Heard: heard})
	return ref
}

// assembleFixture writes two takes (0.5 s lead, 1 s tone, 0.5 s tail) and
// returns a job whose chunks pick them: 1.08 s, a 0.7 s pause, 1.08 s.
func assembleFixture(t *testing.T, f *fakePorts) (*producer, *job) {
	t.Helper()
	return assembleFixtureAs(t, f, assembleID, filepath.Join(t.TempDir(), "v.wav"))
}

// assembleFixtureAs is assembleFixture for project id publishing at out.
func assembleFixtureAs(t *testing.T, f *fakePorts, id, out string) (*producer, *job) {
	t.Helper()
	p := newProducer(f)
	p.start()
	t.Cleanup(func() { p.shutdown() })
	dir := filepath.Join(f.home, produceDir, id)
	if err := os.MkdirAll(filepath.Join(dir, vproject.TakesDir), 0o700); err != nil {
		t.Fatal(err)
	}
	m := &vproject.Manifest{Version: vproject.Version, ID: id,
		Settings: vproject.Settings{LUFS: -16, OutPath: out}}
	for i, text := range []string{"Первое предложение здесь.", "Второе."} {
		key := strings.Repeat(string(rune('a'+i)), 24)
		ref := writeTake(t, dir, key, fixtureTake(48000), text)
		m.Chunks = append(m.Chunks, vproject.Chunk{Index: i, Text: text, PauseAfter: 0.7, Status: vproject.ChunkOK, Pick: key, Takes: []vproject.TakeRef{ref}})
	}
	m.Chunks[1].PauseAfter = 0
	return p, &job{dir: dir, m: m, regen: map[int]int{}}
}

func assembledStem(j *job) string { return strings.TrimSuffix(j.m.Settings.OutPath, ".wav") }

// noOutputs fails when any of the five outputs or a temp file exists.
func noOutputs(t *testing.T, j *job) {
	t.Helper()
	for _, ext := range outputExts {
		if _, err := os.Lstat(assembledStem(j) + ext); !os.IsNotExist(err) {
			t.Errorf("%s was published: %v", ext, err)
		}
	}
	for _, d := range []string{filepath.Dir(j.m.Settings.OutPath), filepath.Join(j.dir, vproject.WorkDir)} {
		entries, _ := os.ReadDir(d)
		for _, e := range entries {
			if strings.Contains(e.Name(), vproject.TempMark) || strings.Contains(e.Name(), ".assembled") {
				t.Errorf("temp file left in %s: %s", d, e.Name())
			}
		}
	}
}

// Trim + exact gaps + one normalisation + timeline words + all outputs.
// Mutation: produce_assemble.go stream, skip Trim -> 4.7 s instead of 2.86 -> RED.
// Mutation: normalise per chunk -> normCalls 2 -> RED.
func TestAssemble(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	if f.normCalls != 1 {
		t.Fatalf("normalise calls %d, want 1", f.normCalls)
	}
	raw, err := os.ReadFile(j.m.Outputs.WAV)
	if err != nil {
		t.Fatal(err)
	}
	c, err := pcm.Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if math.Abs(c.Seconds()-2.86) > timeSlackSec { // 1.08 + 0.7 + 1.08
		t.Fatalf("assembled %.2f s", c.Seconds())
	}
	if c.Rate != 48000 {
		t.Errorf("rate %d, want the engine's 48000", c.Rate)
	}
	if s := j.m.Chunks[1].StartS; math.Abs(s-1.78) > timeSlackSec {
		t.Fatalf("chunk 2 starts at %.2f", s)
	}
	if d := j.m.Outputs.DurationS; math.Abs(d-2.86) > timeSlackSec {
		t.Errorf("recorded duration %.2f", d)
	}
	for _, p := range []string{j.m.Outputs.WAV, j.m.Outputs.SRT, j.m.Outputs.VTT, j.m.Outputs.Words, j.m.Outputs.Manifest} {
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != outFileMode {
			t.Errorf("%s is %v, want %v", filepath.Base(p), st.Mode().Perm(), os.FileMode(outFileMode))
		}
	}
	srt, _ := os.ReadFile(j.m.Outputs.SRT)
	if !strings.Contains(string(srt), "00:00:01,8") || !strings.Contains(string(srt), "Второе.") || !strings.Contains(string(srt), "Первое предложение здесь.") {
		t.Fatalf("srt:\n%s", srt)
	}
	vtt, _ := os.ReadFile(j.m.Outputs.VTT)
	if !strings.HasPrefix(string(vtt), "WEBVTT") {
		t.Errorf("vtt:\n%s", vtt)
	}
	var words []voices.Word
	wj, _ := os.ReadFile(j.m.Outputs.Words)
	if err := json.Unmarshal(wj, &words); err != nil || len(words) != 4 || words[3].W != "Второе." || words[3].S < 1.78 {
		t.Errorf("words.json: %v %+v", err, words)
	}
	if !strings.Contains(string(wj), `"w": "Второе."`) || !strings.Contains(string(wj), `"s": `) || !strings.Contains(string(wj), `"e": `) {
		t.Errorf("words.json keys are not the lowercase w/s/e contract:\n%.200s", wj)
	}
	var export vproject.Manifest
	mj, _ := os.ReadFile(j.m.Outputs.Manifest)
	if err := json.Unmarshal(mj, &export); err != nil || export.Outputs.WAV != j.m.Outputs.WAV || export.Chunks[1].StartS != j.m.Chunks[1].StartS {
		t.Errorf("manifest export: %v %+v", err, export.Outputs)
	}
	entries, _ := os.ReadDir(filepath.Join(j.dir, vproject.WorkDir))
	for _, e := range entries {
		t.Errorf("work file left behind: %s", e.Name())
	}
}

// Normalisation failure publishes nothing (D16).
// Mutation: produce_assemble.go assemble, fall back to the unnormalised file
// when Normalize fails -> v.wav exists -> RED.
func TestAssembleFailsLoudly(t *testing.T) {
	f := newFakePorts(t)
	f.normErr = errors.New("ffmpeg died")
	p, j := assembleFixture(t, f)
	err := p.assemble(j)
	if err == nil || !strings.Contains(err.Error(), "nothing was published") {
		t.Fatalf("assembly without normalisation: %v", err)
	}
	noOutputs(t, j)
	if j.m.Outputs.WAV != "" {
		t.Errorf("outputs recorded for a failed assembly: %+v", j.m.Outputs)
	}
}

// A normaliser that reports success and leaves no usable file publishes nothing.
// Mutation: produce_assemble.go assemble, drop the check of the normalised file -> RED.
func TestAssembleChecksTheNormalisedFile(t *testing.T) {
	f := newFakePorts(t)
	f.normNoop = true
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err == nil {
		t.Fatal("a missing normalised file was published")
	}
	noOutputs(t, j)
}

// What the normaliser leaves is checked, not trusted: a file at another rate
// or without audio is an error and nothing is published.
// Mutation: produce_assemble.go assemble, drop the wavInfoFile check -> RED.
func TestAssembleChecksTheNormalisedRate(t *testing.T) {
	for name, out := range map[string][]byte{
		"other rate": fixtureTake(24000).Encode(),
		"no audio":   pcm.Clip{Rate: 48000}.Encode(),
		"not a wav":  []byte("junk"),
	} {
		f := newFakePorts(t)
		f.normOut = out
		p, j := assembleFixture(t, f)
		if err := p.assemble(j); err == nil {
			t.Errorf("%s: published", name)
		}
		noOutputs(t, j)
	}
}

// A loudness target outside the engine-independent range stops the job before
// any audio is written.
// Mutation: produce_assemble.go assemble, drop the validLUFS call -> RED.
func TestAssembleValidatesTheTarget(t *testing.T) {
	for _, lufs := range []float64{0, -50, math.NaN()} {
		f := newFakePorts(t)
		p, j := assembleFixture(t, f)
		j.m.Settings.LUFS = lufs
		if err := p.assemble(j); err == nil || f.normCalls != 0 {
			t.Errorf("%v LUFS: err %v, normalise calls %d", lufs, err, f.normCalls)
		}
		noOutputs(t, j)
	}
}

// A word the STT places in the tail of the take (or after it) ends with the
// trimmed take, never inside the next chunk's time.
// Mutation: produce_assemble.go add, drop the math.Min(dur, ...) clamp on S, or on E -> RED.
func TestAssembleKeepsWordsInsideTheirChunk(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	late := []voices.Word{{W: "Первое", S: fixtureLead, E: fixtureLead + 0.5}, {W: "предложение", S: 1.0, E: 1.4}, {W: "здесь.", S: 1.9, E: 1.95}} // the last starts in the take's trimmed tail
	d := takeDetail{Ref: j.m.Chunks[0].Takes[0], Heard: late}
	writeDetailT(t, filepath.Join(j.dir, vproject.TakesDir, j.m.Chunks[0].Pick+".json"), d)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	var words []voices.Word
	wj, _ := os.ReadFile(j.m.Outputs.Words)
	if err := json.Unmarshal(wj, &words); err != nil {
		t.Fatal(err)
	}
	end := j.m.Chunks[0].EndS
	for _, w := range words[:3] {
		if w.E > end+timeSlackSec || w.S > end+timeSlackSec || w.S > w.E {
			t.Errorf("%q runs %.2f-%.2f, outside its chunk (ends %.2f)", w.W, w.S, w.E, end)
		}
	}
}

// An output sibling created after job start is not clobbered (write-time check).
// Mutation: produce_assemble.go assemble, drop the second checkOutputs -> RED.
func TestAssembleNoClobberAtWriteTime(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	srt := assembledStem(j) + ".srt"
	f.normHook = func() { _ = os.WriteFile(srt, []byte("mine"), 0o644) }
	if err := p.assemble(j); err == nil {
		t.Fatal("clobbered an .srt created while the job ran")
	}
	if b, _ := os.ReadFile(srt); string(b) != "mine" {
		t.Fatal("user file changed")
	}
	if _, err := os.Stat(j.m.Settings.OutPath); !os.IsNotExist(err) {
		t.Errorf("the wav was published next to a refused sibling: %v", err)
	}
}

// An existing sibling at the start is refused too, unless overwrite is set or
// this project published it.
func TestAssembleNoClobberAtStart(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	wavPath := j.m.Settings.OutPath
	if err := os.WriteFile(wavPath, []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	var re *requestError
	if err := p.assemble(j); !errors.As(err, &re) || f.normCalls != 0 {
		t.Fatalf("err %v, normalise calls %d", err, f.normCalls)
	}
	j.m.Settings.Overwrite = true
	if err := p.assemble(j); err != nil {
		t.Fatalf("overwrite refused: %v", err)
	}
	j.m.Settings.Overwrite = false
	if err := p.assemble(j); err != nil { // its own outputs, recorded in the manifest
		t.Fatalf("re-assembling its own outputs refused: %v", err)
	}
}

// A sibling that is a symlink is never written through, overwrite or not.
// Mutation: produce_assemble.go checkOutputs, drop the ModeSymlink case -> RED.
func TestAssembleRefusesSymlinkedSiblings(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	victim := filepath.Join(t.TempDir(), "victim.txt")
	if err := os.WriteFile(victim, []byte("precious"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, assembledStem(j)+".vtt"); err != nil {
		t.Fatal(err)
	}
	j.m.Settings.Overwrite = true
	if err := p.assemble(j); err == nil {
		t.Fatal("assembled through a symlinked sibling")
	}
	if b, _ := os.ReadFile(victim); string(b) != "precious" {
		t.Fatalf("the symlink target was written: %q", b)
	}
}

// A project directory that escapes the producer root - by "..", or as a
// symlink - is refused before anything is read or written.
// Mutation: produce_assemble.go assemble, drop the vproject.Contained check -> RED.
func TestAssembleRefusesAProjectOutsideTheRoot(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	real := j.dir
	escape := filepath.Join(p.root, "..", filepath.Base(real))
	if err := os.Rename(real, escape); err != nil {
		t.Fatal(err)
	}
	j.dir = escape
	if err := p.assemble(j); err == nil {
		t.Fatal("a project dir outside the root was assembled")
	}
	link := filepath.Join(p.root, "20261015-120000-ffffff")
	if err := os.Symlink(escape, link); err != nil {
		t.Fatal(err)
	}
	j.dir = link
	if err := p.assemble(j); err == nil {
		t.Fatal("a symlinked project dir was assembled")
	}
	if f.normCalls != 0 {
		t.Errorf("normalised %d times", f.normCalls)
	}
}

// Takes of two rates never share a file (the Writer refuses), and the failed
// assembly leaves nothing - not even its temp file.
// Mutation: pcm.Writer.Write, drop the rate check -> RED.
func TestAssembleRefusesMixedRates(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	writeTake(t, j.dir, j.m.Chunks[1].Pick, fixtureTake(24000), "Второе.")
	if err := p.assemble(j); err == nil {
		t.Fatal("a 24 kHz take was mixed into a 48 kHz file")
	}
	if f.normCalls != 0 {
		t.Errorf("normalised a failed assembly")
	}
	noOutputs(t, j)
}

// A pick that is silent after Trim is an error naming its chunk, not a hole.
// Mutation: produce_assemble.go stream, drop the empty-trim check -> RED.
func TestAssembleRefusesASilentPick(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	writeTake(t, j.dir, j.m.Chunks[1].Pick, pcm.Silence(48000, 1), "Второе.")
	err := p.assemble(j)
	if err == nil || !strings.Contains(err.Error(), "chunk 1") {
		t.Fatalf("a silent take was assembled: %v", err)
	}
	noOutputs(t, j)
}

// A pick that names no usable take stops the assembly with the chunk's index:
// unset, a path-shaped key, a missing sidecar, a sidecar of another take, a
// missing WAV.
// The ValidKey check in loadPick keeps a pick from becoming a path at all; the
// sidecar's own key check would refuse it one read later, so it is defence in
// depth and has no mutant of its own.
// Mutation: produce_assemble.go stream, drop `d.Ref.Key != c.Pick` -> RED.
func TestAssembleNeedsUsableTakes(t *testing.T) {
	cases := map[string]func(j *job){
		"no pick":     func(j *job) { j.m.Chunks[1].Pick = "" },
		"path-shaped": func(j *job) { j.m.Chunks[1].Pick = "../../" + strings.Repeat("c", 18) },
		"no sidecar":  func(j *job) { _ = os.Remove(filepath.Join(j.dir, vproject.TakesDir, j.m.Chunks[1].Pick+".json")) },
		"no wav":      func(j *job) { _ = os.Remove(filepath.Join(j.dir, vproject.TakesDir, j.m.Chunks[1].Pick+".wav")) },
		"corrupt wav": func(j *job) {
			_ = os.WriteFile(filepath.Join(j.dir, vproject.TakesDir, j.m.Chunks[1].Pick+".wav"), []byte("junk"), 0o600)
		},
		"other's side": func(j *job) { copySidecar(j, j.m.Chunks[0].Pick, j.m.Chunks[1].Pick) },
	}
	for name, mutate := range cases {
		f := newFakePorts(t)
		p, j := assembleFixture(t, f)
		mutate(j)
		err := p.assemble(j)
		if err == nil || !strings.Contains(err.Error(), "chunk 1") {
			t.Errorf("%s: %v", name, err)
		}
		noOutputs(t, j)
	}
}

func copySidecar(j *job, from, to string) {
	raw, _ := os.ReadFile(filepath.Join(j.dir, vproject.TakesDir, from+".json"))
	_ = os.WriteFile(filepath.Join(j.dir, vproject.TakesDir, to+".json"), raw, 0o600)
}

// A hostile or damaged manifest cannot make the assembly allocate without
// bound or write a malformed gap: a negative, NaN or absurd pause is refused.
// Mutation: produce_assemble.go stream, drop the pause check -> RED.
func TestAssembleRefusesAnAbsurdPause(t *testing.T) {
	for name, pause := range map[string]float64{"negative": -1, "nan": math.NaN(), "inf": math.Inf(1), "days": 86400} {
		f := newFakePorts(t)
		p, j := assembleFixture(t, f)
		j.m.Chunks[0].PauseAfter = pause
		if err := p.assemble(j); err == nil {
			t.Errorf("%s: pause %v accepted", name, pause)
		}
		noOutputs(t, j)
	}
}

// A gap longer than one block is written whole.
// Mutation: produce_assemble.go writeSilence, drop the remainder block -> RED.
func TestWriteSilenceIsExact(t *testing.T) {
	const rate = 48000
	for _, sec := range []float64{0, 0.7, silenceBlockSec, silenceBlockSec + 2.5, 3*silenceBlockSec + 0.25} {
		f, err := os.Create(filepath.Join(t.TempDir(), "s.wav"))
		if err != nil {
			t.Fatal(err)
		}
		w, err := pcm.NewWriter(f, rate)
		if err != nil {
			t.Fatal(err)
		}
		if err := writeSilence(w, rate, sec); err != nil {
			t.Fatal(err)
		}
		if err := w.Close(); err != nil {
			t.Fatal(err)
		}
		raw, _ := os.ReadFile(f.Name())
		c, err := pcm.Decode(raw)
		if err != nil || len(c.S) != int(math.Round(sec*rate)) {
			t.Errorf("%.2f s: %v, %d samples, want %d", sec, err, len(c.S), int(math.Round(sec*rate)))
		}
	}
}

// ENOSPC, bare or wrapped, becomes plain words; anything else passes through.
// Mutation: produce_assemble.go diskErr, return err -> RED.
func TestDiskErrIsPlainWords(t *testing.T) {
	for name, err := range map[string]error{
		"bare":    syscall.ENOSPC,
		"wrapped": fmt.Errorf("write x: %w", &os.PathError{Op: "write", Path: "/x", Err: syscall.ENOSPC}),
	} {
		if got := diskErr(err); !errors.Is(got, errDiskFull) {
			t.Errorf("%s: %v", name, got)
		}
	}
	other := errors.New("boom")
	if diskErr(other) != other || diskErr(nil) != nil {
		t.Error("diskErr changed an unrelated error")
	}
}

// Across volumes rename fails with EXDEV; the file is copied beside its
// destination and renamed there, so a reader never sees a half-copied WAV.
// Mutation: produce_assemble.go moveFile, return the rename error -> RED.
func TestMoveFileAcrossVolumes(t *testing.T) {
	orig := renameFile
	t.Cleanup(func() { renameFile = orig })
	renameFile = func(from, to string) error {
		if strings.Contains(filepath.Base(from), vproject.TempMark) { // the same-volume rename of the copy
			return os.Rename(from, to)
		}
		return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
	}
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "src.wav"), filepath.Join(dir, "dst.wav")
	if err := os.WriteFile(src, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := moveFile(src, dst); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(dst); string(b) != "audio" {
		t.Errorf("dst holds %q", b)
	}
	if st, _ := os.Stat(dst); st.Mode().Perm() != outFileMode {
		t.Errorf("mode %v", st.Mode().Perm())
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), vproject.TempMark) {
			t.Errorf("temp left: %s", e.Name())
		}
	}
}

// A burst rename that cannot complete (here: the third sibling's path is a
// directory) leaves no mixed set: every output file is removed, the
// directory that is not ours stays, and the error says what happened.
// Mutation: produce_assemble.go publish, drop the removeOutputs call -> RED.
// Mutation: produce_assemble.go removeOutputs, drop the IsDir guard -> the empty directory is deleted -> RED.
func TestPublishRollsBackWhatItCreated(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	j.m.Settings.Overwrite = true
	stem := assembledStem(j)
	if err := os.MkdirAll(stem+".words.json", 0o755); err != nil { // empty: only the IsDir guard keeps it
		t.Fatal(err)
	}
	err := p.assemble(j)
	if !errors.Is(err, errOutputsRemoved) {
		t.Fatalf("publishing over a directory: %v", err)
	}
	for _, ext := range []string{".wav", ".srt", ".vtt", ".manifest.json"} {
		if _, err := os.Lstat(stem + ext); !os.IsNotExist(err) {
			t.Errorf("%s survived a failed publish: %v", ext, err)
		}
	}
	if st, err := os.Stat(stem + ".words.json"); err != nil || !st.IsDir() {
		t.Errorf("the user's own directory was touched: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Dir(stem))
	for _, e := range entries {
		if strings.Contains(e.Name(), vproject.TempMark) {
			t.Errorf("staged temp left: %s", e.Name())
		}
	}
	if j.m.Outputs.WAV != "" {
		t.Errorf("outputs recorded for a failed publish: %+v", j.m.Outputs)
	}
}

// outputSet reads the five outputs of j's stem.
func outputSet(t *testing.T, j *job) map[string]string {
	t.Helper()
	set := map[string]string{}
	for _, ext := range outputExts {
		raw, err := os.ReadFile(assembledStem(j) + ext)
		if err != nil {
			t.Fatal(err)
		}
		set[ext] = string(raw)
	}
	return set
}

func failRenames(t *testing.T, fails func(from, to string) bool, err error) {
	t.Helper()
	orig := renameFile
	t.Cleanup(func() { renameFile = orig })
	renameFile = func(from, to string) error {
		if fails(from, to) {
			return err
		}
		return os.Rename(from, to)
	}
}

func noTemps(t *testing.T, dir string) {
	t.Helper()
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), vproject.TempMark) {
			t.Errorf("temp left in %s: %s", dir, e.Name())
		}
	}
}

// editForReassembly changes what the next assembly would publish.
func editForReassembly(j *job) {
	j.m.Chunks[0].Text = "Совсем другой текст."
	j.m.Chunks[0].PauseAfter = 1.5
}

// A WAV that cannot be staged (permission, full disk on the copy) fails the
// re-assembly BEFORE any output is touched: the previous set stays whole.
// Mutation: produce_assemble.go publish, write the siblings before staging the
// WAV (stage per file and rename at once) -> the old wav stays beside new siblings -> RED.
func TestReassemblyWAVStagingFailureLeavesThePreviousSet(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	before := outputSet(t, j)
	editForReassembly(j)
	failRenames(t, func(from, _ string) bool { return strings.HasSuffix(from, normSuffix) }, errors.New("permission denied"))
	if err := p.assemble(j); err == nil {
		t.Fatal("assembly succeeded although the wav could not be staged")
	}
	after := outputSet(t, j)
	for ext, was := range before {
		if after[ext] != was {
			t.Errorf("%s changed although the assembly failed", ext)
		}
	}
	noTemps(t, filepath.Dir(assembledStem(j)))
}

// A rename that fails inside the final burst, after at least one output was
// replaced, leaves no mixed set: none of the five exist, and no temp is left.
// The first rename of the burst (.srt) replaces nothing yet, so its failure
// keeps the previous set whole (TestReassemblyFirstRenameFailureKeepsThePreviousSet).
// Mutation: produce_assemble.go publish, drop the removeOutputs call -> RED.
func TestReassemblyBurstFailureLeavesNoMixedSet(t *testing.T) {
	for _, ext := range outputExts {
		if ext == ".srt" {
			continue
		}
		f := newFakePorts(t)
		p, j := assembleFixture(t, f)
		if err := p.assemble(j); err != nil {
			t.Fatal(err)
		}
		editForReassembly(j)
		dest := assembledStem(j) + ext
		failRenames(t, func(from, to string) bool {
			return to == dest && strings.Contains(filepath.Base(from), vproject.TempMark)
		}, errors.New("disk on fire"))
		err := p.assemble(j)
		if !errors.Is(err, errOutputsRemoved) {
			t.Errorf("%s: error %v", ext, err)
		}
		for _, e := range outputExts {
			if _, serr := os.Lstat(assembledStem(j) + e); !os.IsNotExist(serr) {
				t.Errorf("failing %s left %s behind", ext, e)
			}
		}
		noTemps(t, filepath.Dir(dest))
	}
}

// The first rename of the burst failing replaces nothing: the previous good
// set stays whole and the error says so (#154.8).
// Mutation: produce_assemble.go publish, call removeOutputs for k == 0 too -> the old set is deleted -> RED.
func TestReassemblyFirstRenameFailureKeepsThePreviousSet(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	before := outputSet(t, j)
	editForReassembly(j)
	dest := assembledStem(j) + ".srt"
	failRenames(t, func(from, to string) bool {
		return to == dest && strings.Contains(filepath.Base(from), vproject.TempMark)
	}, errors.New("disk on fire"))
	if err := p.assemble(j); !errors.Is(err, errOutputsKept) {
		t.Fatalf("error %v", err)
	}
	for ext, was := range outputSet(t, j) {
		if was != before[ext] {
			t.Errorf("%s changed although no rename succeeded", ext)
		}
	}
	noTemps(t, filepath.Dir(dest))
}

// One directory sync after the burst, once the last file is placed - renamed
// over the project's own, or linked at a new name (#154.9).
// Mutation: produce_assemble.go publish, delete the syncOutputDir call -> RED.
// Mutation: move the syncOutputDir call into the rename loop -> 5 calls -> RED.
func TestPublishSyncsTheOutputDirOnceAfterTheBurst(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	var renamed, syncs, renamedAtSync int
	origRename, origLink, origSync := renameFile, linkFile, syncOutputDir
	t.Cleanup(func() { renameFile, linkFile, syncOutputDir = origRename, origLink, origSync })
	renameFile = func(from, to string) error {
		if strings.Contains(filepath.Base(from), vproject.TempMark) && !strings.Contains(filepath.Base(to), vproject.TempMark) {
			renamed++
		}
		return origRename(from, to)
	}
	linkFile = func(from, to string) error { // a first publish claims its names with link(2)
		renamed++
		return origLink(from, to)
	}
	syncOutputDir = func(dir string) error {
		syncs++
		renamedAtSync = renamed
		if dir != filepath.Dir(j.m.Settings.OutPath) {
			t.Errorf("synced %s", dir)
		}
		return nil
	}
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	if syncs != 1 || renamedAtSync != len(outputExts) {
		t.Fatalf("%d syncs, %d of %d renames done at the sync", syncs, renamedAtSync, len(outputExts))
	}
}

// The export is written after the final status, elapsed and ETA are known; it
// must not say "running" (#154.6).
// Mutation: produce_assemble.go publish, delete the finalizeExport call -> status "" -> RED.
func TestExportCarriesTheFinalStatus(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	j.started = time.Now().Add(-5 * time.Second)
	j.m.Status, j.m.Progress.ETAS = vproject.StatusRunning, 99
	j.m.Chunks[1].Status = vproject.ChunkReview
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	var export vproject.Manifest
	raw, _ := os.ReadFile(j.m.Outputs.Manifest)
	if err := json.Unmarshal(raw, &export); err != nil {
		t.Fatal(err)
	}
	if export.Status != vproject.StatusReview || export.Progress.ETAS != 0 || export.Progress.ElapsedS < 5 || export.Progress.ElapsedS != j.elapsedS {
		t.Fatalf("export status %q eta %v elapsed %v (job %v)", export.Status, export.Progress.ETAS, export.Progress.ElapsedS, j.elapsedS)
	}
}

// A review chunk whose every take is silent does not fail the job: the file is
// made with the gap and no speech (#154 amendment 3; F1-4 Noted).
// Mutation: produce_assemble.go add, drop the ChunkReview exception -> the assembly fails -> RED.
func TestAssembleToleratesASilentReviewChunk(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	writeTake(t, j.dir, j.m.Chunks[1].Pick, pcm.Silence(48000, 1), "Второе.")
	j.m.Chunks[1].Status = vproject.ChunkReview
	if err := p.assemble(j); err != nil {
		t.Fatalf("a review chunk with a silent take failed the assembly: %v", err)
	}
	if j.m.Chunks[1].EndS != j.m.Chunks[1].StartS {
		t.Errorf("silent chunk has a span %v..%v", j.m.Chunks[1].StartS, j.m.Chunks[1].EndS)
	}
}

// The normalised file must be as long as the timeline: a result cut short (or
// padded) is not published.
// Mutation: produce_assemble.go assemble, drop the math.Abs(secs-tl.total) test -> RED.
func TestAssembleChecksTheNormalisedLength(t *testing.T) {
	short := pcm.Clip{Rate: 48000, S: toneClip(1, 0).S[:9600]} // 0.2 s against a 2.86 s timeline
	long := pcm.Clip{Rate: 48000, S: append(append([]int16{}, toneClip(1, 0).S...), make([]int16, 48000*4)...)}
	for name, clip := range map[string]pcm.Clip{"0.2 s": short, "padded to 5 s": long} {
		f := newFakePorts(t)
		f.normOut = clip.Encode()
		p, j := assembleFixture(t, f)
		err := p.assemble(j)
		if err == nil || !strings.Contains(err.Error(), "nothing was published") {
			t.Errorf("%s: %v", name, err)
		}
		noOutputs(t, j)
	}
}

// the limiter note is recorded, in the job and in the export, and
// cleared again when a later assembly keeps one gain.
// Mutation: produce_assemble.go assemble, drop the withNote call -> RED.
func TestAssembleRecordsLimitedLoudness(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	if hasNote(j.m.Notes) {
		t.Fatalf("a linear result carries the limiter note: %v", j.m.Notes)
	}
	f.normLimited = true
	if err := p.assemble(j); err != nil {
		t.Fatal(err)
	}
	var export vproject.Manifest
	raw, _ := os.ReadFile(j.m.Outputs.Manifest)
	if err := json.Unmarshal(raw, &export); err != nil || !hasNote(j.m.Notes) || !hasNote(export.Notes) {
		t.Fatalf("job notes %v, export notes %v (%v)", j.m.Notes, export.Notes, err)
	}
	f.normLimited = false
	if err := p.assemble(j); err != nil || hasNote(j.m.Notes) {
		t.Fatalf("the note outlived an unlimited assembly: %v %v", err, j.m.Notes)
	}
}

func hasNote(notes []string) bool {
	for _, n := range notes {
		if n == vproject.NoteLimitedLoudness {
			return true
		}
	}
	return false
}

// The output name must be a .wav (any case); siblings share its stem.
// Mutation: produce_assemble.go outputStem, drop the extension check -> RED.
func TestOutputStem(t *testing.T) {
	for in, want := range map[string]string{"/a/v.wav": "/a/v", "/a/V.WAV": "/a/V", "/a/my.reel.wav": "/a/my.reel"} {
		if got, err := outputStem(in); err != nil || got != want {
			t.Errorf("%s: %q %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "/a/v", "/a/v.mp3", "/a/.wav", "rel/v.wav"} {
		if _, err := outputStem(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

// Sidecars written before voices.Word carried json tags have "W"/"S"/"E" keys;
// they must still decode, or every stored take would lose its heard words.
// Mutation: voices/refcut.go, change a tag to a different name -> RED.
func TestSidecarsWithUntaggedWordKeysStillDecode(t *testing.T) {
	key := strings.Repeat("a", 24)
	path := filepath.Join(t.TempDir(), key+".json")
	old := `{"ref":{"key":"` + key + `","seed":1,"attempt":0,"cfg_value":2,"duration_s":1,"wer":0,"passed":true},"heard":[{"W":"раз","S":0.5,"E":0.9}]}`
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := readDetail(path)
	if err != nil || len(d.Heard) != 1 || d.Heard[0].W != "раз" || d.Heard[0].S != 0.5 || d.Heard[0].E != 0.9 {
		t.Fatalf("%v %+v", err, d.Heard)
	}
}

// Re-assembly overwrites only files the project can prove are its own: the
// files at its out_path may since have been moved away and replaced by another
// project's, or the user may have saved their own v.wav over the published
// one. Neither is replaced without overwrite (review round 1, data loss).
// Mutation: produce_assemble.go ownedOutputs, return every stem+ext path -> RED.
// Mutation: produce_ops.go ownedPaths, drop the export-ID check -> the first case is RED.
// Mutation: produce_ops.go ownedPaths, drop the WAV sha check -> the second case is RED.
func TestReassemblyNeverReplacesFilesThatAreNotItsOwn(t *testing.T) {
	t.Run("another project published there", func(t *testing.T) {
		f := newFakePorts(t)
		out := filepath.Join(t.TempDir(), "v.wav")
		p, a := assembleFixtureAs(t, f, assembleID, out)
		if err := p.assemble(a); err != nil {
			t.Fatal(err)
		}
		away := t.TempDir() // the user moves A's files elsewhere
		for _, ext := range outputExts {
			if err := os.Rename(strings.TrimSuffix(out, ".wav")+ext, filepath.Join(away, "v"+ext)); err != nil {
				t.Fatal(err)
			}
		}
		_, b := assembleFixtureAs(t, f, "20261015-130000-b1b2b3", out)
		if err := p.assemble(b); err != nil {
			t.Fatal(err)
		}
		before := outputSet(t, b)
		editForReassembly(a)
		if err := p.assemble(a); err == nil || !strings.Contains(err.Error(), "move or rename") {
			t.Fatalf("A replaced B's files: %v", err)
		}
		for ext, was := range outputSet(t, b) {
			if was != before[ext] {
				t.Errorf("B's %s was changed by A", ext)
			}
		}
	})
	t.Run("the user saved their own wav over it", func(t *testing.T) {
		f := newFakePorts(t)
		p, a := assembleFixture(t, f)
		if err := p.assemble(a); err != nil {
			t.Fatal(err)
		}
		wav := assembledStem(a) + ".wav"
		if err := os.WriteFile(wav, []byte("my own recording"), 0o644); err != nil {
			t.Fatal(err)
		}
		editForReassembly(a)
		if err := p.assemble(a); err == nil || !strings.Contains(err.Error(), "move or rename") {
			t.Fatalf("the user's file was replaced: %v", err)
		}
		if raw, _ := os.ReadFile(wav); string(raw) != "my own recording" {
			t.Fatalf("the user's file was changed: %q", raw)
		}
	})
}
