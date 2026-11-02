package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// The bulk chunk view and the delivery loudness change: one manifest read
// serves every chunk's detail, and a loudness-only delivery re-assembles at
// the new target without a render.

// T11: chunksDetail answers every chunk in the shape chunkDetail serves, out
// of one manifest read, and a settled chunk lists its take files.
// Mutation: produce_ops.go detailOf, drop TakeFiles -> the bulk and the
// single read both go empty -> RED on the non-empty check.
func TestChunksDetailReturnsEveryChunkInOneRead(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	all, err := p.chunksDetail(s.ID)
	if err != nil || len(all) != 2 {
		t.Fatalf("chunks %d err %v, want 2", len(all), err)
	}
	one, err := p.chunkDetail(s.ID, 1)
	if err != nil {
		t.Fatal(err)
	}
	if all[1].Text != one.Text || len(all[1].TakeFiles) != len(one.TakeFiles) {
		t.Fatalf("bulk row differs from the single read: %+v vs %+v", all[1], one)
	}
	if len(all[1].TakeFiles) == 0 {
		t.Fatal("a settled chunk lists no take files")
	}
}

// T11: the route is registered and carries every chunk; an id that is not a
// project gets the daemon's own 404, not the mux's.
func TestChunksRouteServesEveryChunk(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.","voice":"nar","out_path":"`+out+`"}`)
	rec := do(mux, http.MethodGet, "/v1/produce/"+id+"/chunks", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var body struct {
		Chunks []chunkDetailOut `json:"chunks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Chunks) != 2 || body.Chunks[0].Text == "" || len(body.Chunks[0].TakeFiles) == 0 {
		t.Fatalf("chunks: %+v", body.Chunks)
	}
	rec = do(mux, http.MethodGet, "/v1/produce/nope/chunks", "")
	if rec.Code != http.StatusNotFound || !bytes.Contains(rec.Body.Bytes(), []byte("no such voiceover project")) {
		t.Fatalf("unknown id: %d %s", rec.Code, rec.Body)
	}
}

// T11: a delivery carrying loudness_lufs and no chunk entries re-assembles
// the file at the new target — no render, no checkpoint — and the manifest
// keeps it. With no loudness either, an empty batch is still refused.
// Mutation: produce_ops.go deliver, drop `j.m.Settings.LUFS = *lufs` -> the
// old target stays -> RED.
func TestLoudnessOnlyDeliveryReassemblesWithoutRendering(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	renders, quiet := len(f.renders), countEvent(f, "quiet")
	if _, err := p.delivery(s.ID, nil, ptr(-18.0)); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	m, err := p.manifest(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if m.Settings.LUFS != -18 || len(f.renders) != renders {
		t.Fatalf("lufs %v, renders %d -> %d", m.Settings.LUFS, renders, len(f.renders))
	}
	if got := f.normTargets[len(f.normTargets)-1]; got != -18 {
		t.Fatalf("re-assembled at %v LUFS, want -18", got)
	}
	if got := countEvent(f, "quiet") - quiet; got != 0 {
		t.Fatalf("a loudness-only delivery entered the checkpoint %d times", got)
	}
	if _, err := p.delivery(s.ID, nil, nil); err == nil {
		t.Fatal("an empty delivery with no loudness must still be refused")
	}
}

// T11: an out-of-range loudness is refused before anything in the batch is
// applied — a valid entry beside it does not move, and no run starts. That
// holds for a loudness-only delivery too.
// Mutation: produce_ops.go deliver, move the validLUFS check after the apply
// loop -> the entry's pause is stored -> RED on the manifest diff.
func TestDeliveryBadLoudnessAppliesNothing(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	before := manifestBytes(t, f, s.ID)
	renders, norms := len(f.renders), f.normCalls
	n, pause, lufs := 0, 1.0, -3.0 // -3 is louder than maxLUFS
	if _, err := p.delivery(s.ID, []deliveryEntry{{N: &n, PauseAfter: &pause}}, &lufs); err == nil {
		t.Fatal("an out-of-range loudness was accepted")
	}
	if _, err := p.delivery(s.ID, nil, &lufs); err == nil {
		t.Fatal("an out-of-range loudness-only delivery was accepted")
	}
	if got := manifestBytes(t, f, s.ID); !bytes.Equal(before, got) {
		t.Fatal("a refused loudness moved the manifest")
	}
	if len(f.renders) != renders || f.normCalls != norms {
		t.Fatal("a refused loudness launched a run")
	}
}

// T11: over HTTP loudness_lufs sits next to chunks; a bad one is a 400 before
// anything moves, a good one alone is a 202 that re-assembles at the target.
func TestLoudnessDeliveryHTTP(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.","voice":"nar","out_path":"`+out+`"}`)
	before := manifestBytes(t, f, id)
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":0,"pause_after":1.0}],"loudness_lufs":-3}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("bad loudness beside a valid entry: %d %s", rec.Code, rec.Body)
	}
	if got := manifestBytes(t, f, id); !bytes.Equal(before, got) {
		t.Fatal("a refused loudness moved the batch over HTTP")
	}
	rec = do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"loudness_lufs":-18}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("loudness-only delivery: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if m := manifestOf(t, f, id); m.Settings.LUFS != -18 {
		t.Fatalf("lufs %v, want -18", m.Settings.LUFS)
	}
	if got := f.normTargets[len(f.normTargets)-1]; got != -18 {
		t.Fatalf("re-assembled at %v LUFS, want -18", got)
	}
}

// T11: the loudness a delivery set lives in the manifest: a fresh producer
// (the restart case) reads it back, and a later re-render's re-assembly still
// normalises to it.
func TestLoudnessSurvivesRestartAndEdit(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	if _, err := p.delivery(s.ID, nil, ptr(-20.0)); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)

	// A fresh producer over the same root stands in for a daemon restart.
	p2 := newProducer(f)
	p2.start()
	t.Cleanup(func() { p2.shutdown() })
	m, err := p2.manifest(s.ID)
	if err != nil || m.Settings.LUFS != -20 {
		t.Fatalf("after restart: lufs %v err %v", m.Settings.LUFS, err)
	}
	if _, err := p2.chunk(s.ID, 1, chunkOp{Action: opEdit, Text: "Третье, исправленное."}); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p2, s.ID)
	if m, err = p2.manifest(s.ID); err != nil || m.Settings.LUFS != -20 {
		t.Fatalf("after edit: lufs %v err %v", m.Settings.LUFS, err)
	}
	if got := f.normTargets[len(f.normTargets)-1]; got != -20 {
		t.Fatalf("the edit's re-assembly normalised at %v LUFS, want -20", got)
	}
}

// A loudness-only delivery whose re-assembly fails on a finished project
// must not cost it its finished state (#417): the status it had is restored,
// the loudness target the manifest carries stays the one the published file
// was made at, the file and its outputs are untouched, and the failure is on
// the project's error field so the app can say what happened.
// Mutation: produce_ops.go deliver, persist the new target into the manifest
// before the run again -> lufs is -18 and the status failed -> RED.
func TestLoudnessOnlyFailureKeepsTheFinishedState(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	m, err := p.manifest(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	lufs0, wav := m.Settings.LUFS, m.Outputs.WAV
	published, err := os.ReadFile(wav)
	if err != nil {
		t.Fatal(err)
	}
	f.normErr = errors.New("ffmpeg died")

	if _, err := p.delivery(s.ID, nil, ptr(-18.0)); err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)

	m, err = p.manifest(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if m.Status != vproject.StatusDone || m.Settings.LUFS != lufs0 || m.Outputs.WAV != wav {
		t.Fatalf("after the failed re-assembly: status %q lufs %v wav %q", m.Status, m.Settings.LUFS, m.Outputs.WAV)
	}
	if !strings.Contains(m.Error, "ffmpeg died") {
		t.Fatalf("the failure is not on the project: error %q", m.Error)
	}
	if after, err := os.ReadFile(wav); err != nil || !bytes.Equal(published, after) {
		t.Fatalf("the published file changed: %v", err)
	}
}

// A loudness-only delivery on a project that has not finished is a 409, not
// a hidden resume: nothing launches, nothing renders and the manifest is
// untouched. The project finishes through resume, never through delivery.
// Mutation: produce_ops.go deliver, drop the countSettled refusal -> a run
// with real renders -> RED.
func TestLoudnessOnlyOnUnfinishedIsRefused(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	p := newProducer(f)
	p.start()
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	p.shutdown() // the daemon stopped mid-render: interrupted, chunks pending
	m, err := vproject.Load(filepath.Join(f.home, produceDir, s.ID))
	if err != nil || m.Status != vproject.StatusInterrupted {
		t.Fatalf("%v %+v", err, m)
	}
	before := manifestBytes(t, f, s.ID)
	renders := len(f.renders)

	p2 := newProducer(f) // a fresh producer stands in for the daemon after the restart
	p2.start()
	t.Cleanup(func() { p2.shutdown() })
	if _, err := p2.delivery(s.ID, nil, ptr(-18.0)); produceStatusCode(err) != http.StatusConflict {
		t.Fatalf("delivery on an unfinished project: %v", err)
	}
	if got := manifestBytes(t, f, s.ID); !bytes.Equal(before, got) {
		t.Fatal("the refused loudness changed the manifest")
	}
	if len(f.renders) != renders {
		t.Fatalf("the refused loudness rendered %d takes", len(f.renders)-renders)
	}
}
