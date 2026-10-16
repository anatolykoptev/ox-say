package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// paceFrameSec is the tolerance for "within one frame" duration claims:
// atempo quantizes to its analysis window (a few ms measured), a video
// frame at 30 fps is 33 ms.
const paceFrameSec = 1.0 / 30

// paceScript makes three chunks (backticks keep \n literal for the JSON
// body); chunk 1 is a three-word sentence so its words' middle positions
// prove the 1/rate scaling (a one-word chunk's single span-end could not).
const paceScript = `Первое. Второе.\n\nТретье и четвёртое.\n\nПятое.`

// needFFmpeg skips when ffmpeg is absent: the stretch tests exercise the
// real binary, and CI's gate job installs it.
func needFFmpeg(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg is not on PATH; pace tests need the real binary (CI installs it)")
	}
}

// readWordsJSON parses the published words.json.
func readWordsJSON(t *testing.T, path string) []voices.Word {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var ws []voices.Word
	if err := json.Unmarshal(raw, &ws); err != nil {
		t.Fatal(err)
	}
	return ws
}

var srtCueRe = regexp.MustCompile(`(\d\d):(\d\d):(\d\d),(\d\d\d) --> (\d\d):(\d\d):(\d\d),(\d\d\d)`)

// srtCueSpans parses every cue's start/end seconds out of a subtitle file.
func srtCueSpans(t *testing.T, path string) [][2]float64 {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out [][2]float64
	for _, m := range srtCueRe.FindAllStringSubmatch(string(raw), -1) {
		out = append(out, [2]float64{srtSeconds(m[1:5]), srtSeconds(m[5:9])})
	}
	if len(out) == 0 {
		t.Fatalf("no cues in %s", path)
	}
	return out
}

func srtSeconds(f []string) float64 {
	h, _ := strconv.Atoi(f[0])
	m, _ := strconv.Atoi(f[1])
	s, _ := strconv.Atoi(f[2])
	ms, _ := strconv.Atoi(f[3])
	return float64(h*3600+m*60+s) + float64(ms)/1000
}

// spanOwner attributes a timed thing to its chunk: chunk spans never
// overlap, so the chunk whose span contains the start owns it. A time in
// a pause gap belongs to nothing.
func spanOwner(chunks []vproject.Chunk, at float64) int {
	for i := range chunks {
		if at >= chunks[i].StartS-0.005 && at <= chunks[i].EndS+0.005 {
			return i
		}
	}
	return -1
}

// P1: a pace on one chunk stretches its trimmed clip with ffmpeg atempo —
// the assembly is shorter by the stretch, no take renders, the checkpoint
// is never entered, and the new pace shows in the chunk's detail.
// Mutation: produce_assemble.go tl.add, drop the stretch call -> the
// assembled length does not drop -> RED.
func TestDeliveryPaceReassemblesOnly(t *testing.T) {
	needFFmpeg(t)
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"`+paceScript+`","voice":"nar","out_path":"`+out+`"}`)
	m := manifestOf(t, f, id)
	len1 := m.Chunks[1].EndS - m.Chunks[1].StartS
	if len1 <= 0 {
		t.Fatalf("chunk 1 has no span: %+v", m.Chunks[1])
	}
	_, dur0 := wavInfoFile(out)
	renders, quiet, hears, norms := len(f.renders), countEvent(f, "quiet"), f.hears, f.normCalls
	want := len1 * (1 - 1/1.10)
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"pace":1.10}]}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	m = manifestOf(t, f, id)
	_, dur1 := wavInfoFile(out)
	if drop := dur0 - dur1; math.Abs(drop-want) > paceFrameSec {
		t.Errorf("assembled dropped %v s, want ~%v (pace 1.10 on a %.2f s chunk)", drop, want, len1)
	}
	if got := len(f.renders) - renders; got != 0 {
		t.Errorf("%d takes rendered", got)
	}
	if got := countEvent(f, "quiet") - quiet; got != 0 {
		t.Errorf("the checkpoint ran %d times", got)
	}
	if got := f.hears - hears; got != 0 {
		t.Errorf("a pace transcribed %d times", got)
	}
	if got := f.normCalls - norms; got != 1 {
		t.Errorf("assemblies ran %d times, want 1", got)
	}
	for i, c := range m.Chunks {
		if c.Status != vproject.ChunkOK || len(c.Pick) != takeKeyBytes*2 {
			t.Fatalf("chunk %d lost its pick: %+v", i, c)
		}
	}
	var det chunkDetailOut
	detRec := do(mux, http.MethodGet, "/v1/produce/"+id+"/chunks/1", "")
	if err := json.Unmarshal(detRec.Body.Bytes(), &det); err != nil {
		t.Fatal(err)
	}
	if det.Pace != 1.10 || m.Chunks[1].Pace != 1.10 {
		t.Fatalf("pace detail %v, manifest %v", det.Pace, m.Chunks[1].Pace)
	}
}

// P2: after the stretch, every word time and SRT cue of the paced chunk
// sits at its scaled place inside the new span, and every later chunk's
// words shift by the same delta. The fake heard words split the 2 s take
// evenly, so the expected scaled positions are exact.
// Mutation: produce_assemble.go tl.add, drop the /rate on word times ->
// chunk 1's words land at their unscaled positions -> RED.
func TestDeliveryPaceKeepsWordsInSync(t *testing.T) {
	needFFmpeg(t)
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"`+paceScript+`","voice":"nar","out_path":"`+out+`"}`)
	before := manifestOf(t, f, id)
	words0 := readWordsJSON(t, before.Outputs.Words)
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"pace":1.10}]}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	after := manifestOf(t, f, id)
	words1 := readWordsJSON(t, after.Outputs.Words)
	c1 := after.Chunks[1]
	// Chunk 1's three heard words sit at even thirds of the 2 s take; scaled
	// by 1/rate they must land exactly, or just inside the stretched span
	// when the ideal end exceeds it.
	var mine []voices.Word
	for _, w := range words1 {
		if spanOwner(after.Chunks, w.S) == 1 {
			mine = append(mine, w)
		}
	}
	if len(mine) != 3 {
		t.Fatalf("chunk 1 has %d words in words.json, want 3", len(mine))
	}
	for i, w := range mine {
		hs, he := f.secs*float64(i)/3, f.secs*float64(i+1)/3
		if want := c1.StartS + hs/1.10; math.Abs(w.S-want) > 0.005 {
			t.Errorf("word %d starts %v, want the scaled %v", i, w.S, want)
		}
		if want := he / 1.10; want < c1.EndS-c1.StartS-0.005 {
			if got := c1.StartS + want; math.Abs(w.E-got) > 0.005 {
				t.Errorf("word %d ends %v, want the scaled %v", i, w.E, got)
			}
		} else if w.E > c1.EndS+0.005 || w.E < c1.StartS {
			t.Errorf("word %d ends %v outside the stretched span %v–%v", i, w.E, c1.StartS, c1.EndS)
		}
	}
	for _, cue := range srtCueSpans(t, after.Outputs.SRT) {
		if spanOwner(after.Chunks, cue[0]) != 1 {
			continue
		}
		if cue[1] > c1.EndS+0.005 {
			t.Errorf("cue %v–%v ends past chunk 1's end %v", cue[0], cue[1], c1.EndS)
		}
	}
	for i := 2; i < len(after.Chunks); i++ {
		delta := after.Chunks[i].StartS - before.Chunks[i].StartS
		var ws0, ws1 []voices.Word
		for _, w := range words0 {
			if spanOwner(before.Chunks, w.S) == i {
				ws0 = append(ws0, w)
			}
		}
		for _, w := range words1 {
			if spanOwner(after.Chunks, w.S) == i {
				ws1 = append(ws1, w)
			}
		}
		if len(ws0) == 0 || len(ws0) != len(ws1) {
			t.Fatalf("chunk %d word count %d -> %d", i, len(ws0), len(ws1))
		}
		for k := range ws0 {
			if d := (ws1[k].S - ws0[k].S) - delta; math.Abs(d) > 0.005 {
				t.Errorf("chunk %d word %d start shifted %v, want the chunk delta %v", i, k, ws1[k].S-ws0[k].S, delta)
			}
			if d := (ws1[k].E - ws0[k].E) - delta; math.Abs(d) > 0.005 {
				t.Errorf("chunk %d word %d end shifted %v, want the chunk delta %v", i, k, ws1[k].E-ws0[k].E, delta)
			}
		}
	}
}

// P3: clearing pace reassembles the plain pipeline — the outputs are
// byte-identical to the never-paced ones.
// Mutation: produce_assemble.go tl.add, stretch at every rate including
// neutral (always call stretch) -> the re-encoded clip differs -> RED.
func TestDeliveryPaceClearRestoresBytes(t *testing.T) {
	needFFmpeg(t)
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"`+paceScript+`","voice":"nar","out_path":"`+out+`"}`)
	m := manifestOf(t, f, id)
	outs := []string{m.Outputs.WAV, m.Outputs.SRT, m.Outputs.VTT, m.Outputs.Words}
	before := make([][]byte, len(outs))
	for i, p := range outs {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		before[i] = b
	}
	for _, pace := range []string{"1.10", "0"} {
		rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"pace":`+pace+`}]}`)
		if rec.Code != http.StatusAccepted {
			t.Fatalf("pace %s: %d %s", pace, rec.Code, rec.Body)
		}
		waitDoneHTTP(t, mux, id)
	}
	for i, p := range outs {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(before[i], b) {
			t.Errorf("%s changed after a pace round-trip", filepath.Base(p))
		}
	}
}

// P4: an out-of-range pace is a request error that moves nothing; NaN and
// ±Inf cannot pass through a JSON body, so they go at validateDelivery
// directly.
// Mutation: produce_ops.go validateDelivery, drop deliveryPaceOK -> 1.3 is
// accepted -> RED.
func TestDeliveryPaceBounds(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"`+paceScript+`","voice":"nar","out_path":"`+out+`"}`)
	m0 := manifestBytes(t, f, id)
	for _, pace := range []string{"1.3", "0.84", "-1"} {
		rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","pace":`+pace+`}`)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("pace %s: %d %s", pace, rec.Code, rec.Body)
		}
	}
	n := 1
	for name, pace := range map[string]float64{"NaN": math.NaN(), "+Inf": math.Inf(1), "-Inf": math.Inf(-1), "low": 0.5, "high": 2} {
		m := &vproject.Manifest{Version: vproject.Version, Chunks: make([]vproject.Chunk, 3)}
		if _, err := validateDelivery(m, []deliveryEntry{{N: &n, Pace: &pace}}); err == nil {
			t.Errorf("%s pace %v accepted", name, pace)
		}
	}
	if got := manifestBytes(t, f, id); !bytes.Equal(m0, got) {
		t.Error("the manifest changed on refused paces")
	}
}

// P5: with ffmpeg's atempo unavailable the pace op is refused at op time
// and the manifest does not move; a pause op on the same project still
// works.
// Mutation: produce_ops.go deliver, drop the paceOK call -> the op is
// accepted -> RED.
func TestDeliveryPaceWithoutAtempo(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"`+paceScript+`","voice":"nar","out_path":"`+out+`"}`)
	m0 := manifestBytes(t, f, id)
	old := paceOK
	paceOK = func() error { return errors.New("a pace change needs ffmpeg, which is missing here") }
	t.Cleanup(func() { paceOK = old })
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"pace":1.1}]}`)
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "ffmpeg") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if got := manifestBytes(t, f, id); !bytes.Equal(m0, got) {
		t.Fatal("the manifest changed on a refused pace")
	}
	rec = do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"pause_after":1.0}]}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("pause op after the refusal: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
}

// P6: the stretch's temp clip lives under out/ only for the call — a
// successful and a failed assembly both leave none.
// Mutation: pace.go atempoClip, drop the os.Remove defer -> a temp clip
// stays -> RED.
func TestAssemblyPaceLeavesNoTemp(t *testing.T) {
	needFFmpeg(t)
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	j.m.Chunks[0].Pace = 1.1
	if err := p.assemble(j); err != nil {
		t.Fatalf("assemble: %v", err)
	}
	work := filepath.Join(j.dir, vproject.WorkDir)
	if left, _ := os.ReadDir(work); len(left) != 0 {
		names := []string{}
		for _, e := range left {
			names = append(names, e.Name())
		}
		t.Fatalf("temp files left after a stretch: %v", names)
	}
	useFakeFFmpeg(t, "exit 1")
	f2 := newFakePorts(t)
	p2, j2 := assembleFixture(t, f2)
	j2.m.Chunks[0].Pace = 1.1
	if err := p2.assemble(j2); err == nil {
		t.Fatal("assemble with a broken ffmpeg succeeded")
	}
	if left, _ := os.ReadDir(filepath.Join(j2.dir, vproject.WorkDir)); len(left) != 0 {
		t.Fatalf("temp files left after a failed stretch: %v", left)
	}
}

// P7: a v1 manifest written before Chunk.Pace existed carries no pace key;
// it loads (validate accepts the absent field) and assembles byte-
// identically.
func TestV1ManifestWithoutPaceAssembles(t *testing.T) {
	f := newFakePorts(t)
	p, j := assembleFixture(t, f)
	if err := j.m.Save(j.dir); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(j.dir, "manifest.json"))
	if err != nil || strings.Contains(string(raw), `"pace"`) {
		t.Fatalf("the fixture is not a v1-without-pace manifest: %v", err)
	}
	if err := p.assemble(j); err != nil {
		t.Fatalf("assemble: %v", err)
	}
	outs := []string{j.m.Outputs.WAV, j.m.Outputs.SRT, j.m.Outputs.VTT, j.m.Outputs.Words}
	before := make([][]byte, len(outs))
	for i, path := range outs {
		if before[i], err = os.ReadFile(path); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.m.Save(j.dir); err != nil { // the load path needs the outputs recorded
		t.Fatal(err)
	}
	j2, err := p.open(j.m.ID)
	if err != nil {
		t.Fatal(err)
	}
	for i, c := range j2.m.Chunks {
		if c.Pace != 0 {
			t.Fatalf("chunk %d loaded pace %v from a pace-free manifest", i, c.Pace)
		}
	}
	if err := p.assemble(j2); err != nil {
		t.Fatalf("assemble of the loaded manifest: %v", err)
	}
	for i, path := range outs {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(before[i], b) {
			t.Errorf("%s differs after a load+assemble round-trip", filepath.Base(path))
		}
	}
}
