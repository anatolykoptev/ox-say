package meeting

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// aecTone is the sample the stub ox-aec writes into me.aec.pcm: the me-channel
// wavs the recognizer then gets carry it, which is how a test sees which file
// fed the recognition — not a helper's return value.
const aecTone = 9001

// aecStub writes a tiny fake ox-aec: it parses the real argument list, turns
// the capture into an equal-size me.aec.pcm of aecTone samples (capture is a
// writePCM tone, so a byte-level tr maps every sample), and writes the report
// the mode calls for. mode "exit1" dies without output; "badreport" leaves
// unparseable JSON; "noout" leaves no me.aec.pcm beside a clean report.
func aecStub(t *testing.T, mode string) string {
	t.Helper()
	dir := t.TempDir()
	report := `{"frames":100,"lag_ms":[40.0,41.0,42.0],"lag_measured":[1,1,1],` +
		`"stats":[{"t":0,"delay_ms":40.0,"erl_db":null,"erle_db":25.0,"div_frac":0.0}],` +
		`"render_active":0.5,"diverged":false,"alignment":"measured","apm_latency_samples":128}`
	body := "tr '\\210\\023' '\\051\\043' < \"$cap\" > \"$out\"\nprintf '%s\\n' '" + report + "' > \"$rep\"\n"
	switch mode {
	case "ok":
	case "exit1":
		body = "exit 1\n"
	case "diverged":
		body = strings.ReplaceAll(body, `"diverged":false`, `"diverged":true`)
	case "no_render":
		report = `{"frames":100,"lag_ms":[],"lag_measured":[],"stats":[],` +
			`"render_active":0.0,"diverged":false,"alignment":"unmeasured","skipped":"no_render"}`
		body = "tr '\\210\\023' '\\051\\043' < \"$cap\" > \"$out\"\nprintf '%s\\n' '" + report + "' > \"$rep\"\n"
	case "unmeasured":
		body = strings.ReplaceAll(body, `"lag_measured":[1,1,1]`, `"lag_measured":[0,0,0]`)
		body = strings.ReplaceAll(body, `"alignment":"measured"`, `"alignment":"unmeasured"`)
	case "badreport":
		body = "tr '\\210\\023' '\\051\\043' < \"$cap\" > \"$out\"\nprintf '{not json' > \"$rep\"\n"
	case "silent": // a canceller that removed everything: a clean run whose output is all zeros
		body = "head -c \"$(wc -c < \"$cap\")\" /dev/zero > \"$out\"\nprintf '%s\\n' '" + report + "' > \"$rep\"\n"
	case "noout":
		body = "head -c 100 \"$cap\" > \"$out\"\nprintf '%s\\n' '" + report + "' > \"$rep\"\n"
	case "tmpfail": // a run killed mid-write: the engine's temp names, then death
		body = "printf x > \"$out.tmp\"\nprintf x > \"$rep.tmp\"\nexit 1\n"
	default:
		t.Fatalf("aecStub: unknown mode %q", mode)
	}
	script := `#!/bin/sh
LC_ALL=C
export LC_ALL
cap= out= rep=
while [ $# -gt 0 ]; do
	case "$1" in
		--capture) cap="$2"; shift 2 ;;
		--render) shift 2 ;;
		--out) out="$2"; shift 2 ;;
		--report) rep="$2"; shift 2 ;;
		*) shift ;;
	esac
done
` + body
	bin := filepath.Join(dir, "ox-aec")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// aecRunner wires the runner's AEC dep to the real spawn path over a binary:
// production calls RunAECBin with Cfg.AECBin, a test with the stub's path.
func aecRunner(bin string) func(context.Context, string) (*AECReport, error) {
	return func(ctx context.Context, dir string) (*AECReport, error) {
		return RunAECBin(ctx, bin, dir)
	}
}

// aecSources arms the recognizer spy: for every "me" piece it records whether
// the wav was cut from the canceller's output (the aecTone samples) or from
// the raw channel.
func (f *fixture) aecSources() (cancelled, raw *int) {
	cancelled, raw = new(int), new(int)
	inner := f.r.Transcribe
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if strings.HasPrefix(filepath.Base(wav), "me-") {
			data, _ := os.ReadFile(wav)
			if len(data) >= 46 && binary.LittleEndian.Uint16(data[44:46]) == aecTone {
				*cancelled++
			} else {
				*raw++
			}
		}
		return inner(ctx, wav)
	}
	return cancelled, raw
}

// aecOn turns meeting_aec on the way the settings PUT writes it.
func aecOn(t *testing.T, f *fixture) {
	t.Helper()
	if err := f.r.Store.SetSettings(Settings{RetentionDays: DefaultRetention, AEC: AECOn}); err != nil {
		t.Fatal(err)
	}
}

// wantRawOnly is the assertion every fallback case shares: the me
// channel was recognized from the raw file only.
func wantRawOnly(t *testing.T, cancelled, raw *int) {
	t.Helper()
	if *cancelled != 0 {
		t.Errorf("the recognizer read me.aec.pcm on %d pieces of a run that should have stayed on me.pcm", *cancelled)
	}
	if *raw == 0 {
		t.Error("the recognizer never saw the raw me channel")
	}
}

// The canceller ran clean: the recognizer is fed me.aec.pcm, the manifest
// carries no aec warning, and the stage's numbers reach /status.
// Mutation: internal/meeting/runner.go transcribe, `if meFile != MePCM {` ->
// `if false {` -> RED (the raw file is read after a successful stage).
func TestAECCancelledChannelReachesTheRecognizer(t *testing.T) {
	f, h := stagedFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "ok"))
	cancelled, raw := f.aecSources()
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if *cancelled == 0 || *raw != 0 {
		t.Fatalf("me pieces from aec=%d raw=%d, want all aec and no raw", *cancelled, *raw)
	}
	m := f.load(t, id)
	for _, w := range m.Warnings {
		if strings.HasPrefix(w, "aec_") {
			t.Errorf("clean aec run left warning %q", w)
		}
	}
	dir, _ := f.r.Store.Dir(id)
	for _, name := range []string{MeAECPCM, AECJSON} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s was not written: %v", name, err)
		}
	}
	last := f.r.LastAEC()
	if last == nil || last.Result != stageOK || last.Alignment != "measured" || last.LagMS == nil || last.ERLEdB == nil || last.APMSamples == nil {
		t.Fatalf("LastAEC = %+v, want the ok run's numbers", last)
	}
	var end *capRecord
	for i, r := range h.find("meeting: stage") {
		if r.attrs["stage"] == "aec" && r.attrs["event"] == "end" {
			got := h.find("meeting: stage")[i]
			end = &got
		}
	}
	if end == nil || end.attrs["result"] != stageOK || end.attrs["alignment"] != "measured" ||
		end.attrs["lag_ms"] != "41" || end.attrs["erle_db"] != "25" || end.attrs["apm_latency_samples"] != "128" {
		t.Fatalf("aec stage end = %v, want ok with the report's numbers:\n%s", end, h.text())
	}
}

// meeting_aec off — the never-chosen default or an explicit off: the stage
// logs skipped reason=off, the binary is never spawned, and the run is
// byte-for-byte today's pipeline.
func TestAECOffSpawnsNothing(t *testing.T) {
	for _, setting := range []string{"", AECOff} {
		t.Run("meeting_aec="+strconv.Quote(setting), func(t *testing.T) {
			f := newFixture(t)
			if setting != "" {
				if err := f.r.Store.SetSettings(Settings{RetentionDays: DefaultRetention, AEC: setting}); err != nil {
					t.Fatal(err)
				}
			}
			bin := aecStub(t, "ok") // a stub that would leave its artifacts if it ran
			f.r.AEC = aecRunner(bin)
			cancelled, raw := f.aecSources()
			id := f.start(t, 30, 30, 5000, false)
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			wantRawOnly(t, cancelled, raw)
			dir, _ := f.r.Store.Dir(id)
			for _, name := range []string{MeAECPCM, AECJSON} {
				if _, err := os.Stat(filepath.Join(dir, name)); !errors.Is(err, os.ErrNotExist) {
					t.Errorf("%s exists though the stage was off (the binary ran)", name)
				}
			}
			last := f.r.LastAEC()
			if last == nil || last.Result != stageSkipped || last.Reason != aecReasonOff {
				t.Fatalf("LastAEC = %+v, want skipped/off", last)
			}
		})
	}
}

// The binary is not on the Mac (missing path, or no implementation wired):
// the stage skips as missing, warns aec_missing, and the raw channel is read.
func TestAECMissingBinaryFallsBackToRaw(t *testing.T) {
	for name, wire := range map[string]func(f *fixture){
		"no_binary": func(f *fixture) { f.r.AEC = aecRunner(filepath.Join(t.TempDir(), "ox-aec")) },
		"nil_dep":   func(f *fixture) {},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			aecOn(t, f)
			wire(f)
			cancelled, raw := f.aecSources()
			id := f.start(t, 30, 30, 5000, false)
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			wantRawOnly(t, cancelled, raw)
			if m := f.load(t, id); !slices.Contains(m.Warnings, WarnAECMissing) {
				t.Fatalf("warnings = %v, want %q", m.Warnings, WarnAECMissing)
			}
			last := f.r.LastAEC()
			if last == nil || last.Result != stageSkipped || last.Reason != aecReasonMissing {
				t.Fatalf("LastAEC = %+v, want skipped/missing", last)
			}
		})
	}
}

// The canceller died: non-zero exit, an unreadable report, a diverged filter
// or a short output each warn aec_failed and keep the raw channel — and none
// of them loses the meeting.
// Mutation: internal/meeting/aec.go reportVerdict, `case rep.Diverged:` ->
// `case false:` -> RED in the diverged case (the ruined output is fed to the recognizer).
func TestAECFailureFallsBackToRaw(t *testing.T) {
	for name, mode := range map[string]string{
		"exit1":     "exit1",
		"diverged":  "diverged",
		"badreport": "badreport",
		"noout":     "noout",
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			aecOn(t, f)
			f.r.AEC = aecRunner(aecStub(t, mode))
			cancelled, raw := f.aecSources()
			id := f.start(t, 30, 30, 5000, false)
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			wantRawOnly(t, cancelled, raw)
			m := f.load(t, id)
			if !slices.Contains(m.Warnings, WarnAECFailed) {
				t.Fatalf("warnings = %v, want %q", m.Warnings, WarnAECFailed)
			}
			if m.Status != StatusDone {
				t.Errorf("status = %q: a broken canceller must not lose the meeting", m.Status)
			}
			last := f.r.LastAEC()
			if last == nil || last.Result != stageFailed {
				t.Fatalf("LastAEC = %+v, want a failed stage", last)
			}
		})
	}
}

// The far side never spoke: the engine copies the capture through and asks
// for the raw file — no warning, a silent skip.
func TestAECNoRenderIsASilentSkip(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "no_render"))
	cancelled, raw := f.aecSources()
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	wantRawOnly(t, cancelled, raw)
	if m := f.load(t, id); slices.Contains(m.Warnings, WarnAECFailed) || slices.Contains(m.Warnings, WarnAECMissing) {
		t.Fatalf("warnings = %v, want no aec warning", m.Warnings)
	}
	last := f.r.LastAEC()
	if last == nil || last.Result != stageSkipped || last.Reason != aecReasonNoRender {
		t.Fatalf("LastAEC = %+v, want skipped/no_render", last)
	}
}

// The lag was never measured although the far side was active: logged, and
// the output still stands — AEC3 estimates its own delay.
func TestAECUnmeasuredAlignmentStillFeedsTheCancelledChannel(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "unmeasured"))
	cancelled, _ := f.aecSources()
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if *cancelled == 0 {
		t.Fatal("the recognizer never read me.aec.pcm although the stage was ok")
	}
	last := f.r.LastAEC()
	if last == nil || last.Result != stageOK || last.Alignment != "unmeasured" {
		t.Fatalf("LastAEC = %+v, want ok with alignment=unmeasured", last)
	}
}

// The canceller's artifacts are audio made from the audio: the retention
// sweep retires me.aec.pcm and aec.json beside the channels.
func TestAECArtifactsGoWithTheAudio(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "ok"))
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	for _, name := range []string{MeAECPCM, AECJSON} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Fatalf("%s missing after a clean run: %v", name, err)
		}
	}
	f.now = f.now.Add(400 * 24 * time.Hour)
	if n := f.r.SweepRetention(); n != 1 {
		t.Fatalf("swept %d meetings, want 1", n)
	}
	for _, name := range []string{MePCM, ThemPCM, MeAECPCM, AECJSON} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s survived the sweep", name)
		}
	}
}

// median over a list, for the stage log's single number per report list.
func TestMedian(t *testing.T) {
	for in, want := range map[string]float64{
		"40,41,42": 41,
		"1,2,3,4":  2.5,
		"5":        5,
		"9,1":      5,
	} {
		var vs []float64
		for _, s := range strings.Split(in, ",") {
			v, _ := strconv.ParseFloat(s, 64)
			vs = append(vs, v)
		}
		got, ok := median(vs)
		if !ok || got != want {
			t.Errorf("median(%v) = %v,%v, want %v,true", in, got, ok, want)
		}
	}
	if _, ok := median(nil); ok {
		t.Error("median of nothing reported a value")
	}
}

// A channel file that is gone (retention took the audio) leaves nothing to cancel: the stage skips with no warning
// and never spawns the binary.
func TestAECSkipsWhenAChannelIsGone(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "ok"))
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	if err := os.Remove(filepath.Join(dir, ThemPCM)); err != nil {
		t.Fatal(err)
	}
	file, warns, err := f.r.aecStage(context.Background(), id, dir, newStageLog(f.r.Log, id, f.r.Now))
	if err != nil || file != MePCM || len(warns) != 0 {
		t.Fatalf("aecStage = %q %v %v, want me.pcm, no warning", file, warns, err)
	}
	if _, err := os.Stat(filepath.Join(dir, MeAECPCM)); err == nil {
		t.Fatal("the binary ran on a meeting without its far-side channel")
	}
	if last := f.r.LastAEC(); last == nil || last.Reason != aecReasonNoAudio {
		t.Fatalf("LastAEC = %+v, want skipped/no_audio", last)
	}
}

// An earlier run's output must not pass for this run's: a binary that dies leaves neither file behind.
// Mutation: internal/meeting/aec.go RunAECBin, delete the `for _, name := range []string{MeAECPCM, AECJSON} {` loop
// -> RED (the stale me.aec.pcm is still there after the failed run).
func TestRunAECBinClearsStaleOutputs(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{MePCM, ThemPCM, MeAECPCM, AECJSON} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("old"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := RunAECBin(context.Background(), aecStub(t, "exit1"), dir); err == nil {
		t.Fatal("a failing binary reported success")
	}
	for _, name := range []string{MeAECPCM, AECJSON} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("stale %s survived a failed run", name)
		}
	}
}

// An empty channel file has nothing to cancel — the stage skips as no_audio, exactly like a missing one: no
// warning, and the binary is never spawned.
// Mutation: internal/meeting/aec.go channelsPresent, delete `|| st.Size() == 0` -> RED (the engine runs on an
// empty capture and me.aec.pcm lands in the meeting directory).
func TestAECEmptyChannelGetsNoAudio(t *testing.T) {
	for _, name := range []string{MePCM, ThemPCM} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			aecOn(t, f)
			f.r.AEC = aecRunner(aecStub(t, "ok"))
			id := f.start(t, 30, 30, 5000, false)
			dir, _ := f.r.Store.Dir(id)
			if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
				t.Fatal(err)
			}
			file, warns, err := f.r.aecStage(context.Background(), id, dir, newStageLog(f.r.Log, id, f.r.Now))
			if err != nil || file != MePCM || len(warns) != 0 {
				t.Fatalf("aecStage = %q %v %v, want me.pcm, no warning", file, warns, err)
			}
			if _, err := os.Stat(filepath.Join(dir, MeAECPCM)); err == nil {
				t.Fatal("the binary ran on an empty channel")
			}
			if last := f.r.LastAEC(); last == nil || last.Result != stageSkipped || last.Reason != aecReasonNoAudio {
				t.Fatalf("LastAEC = %+v, want skipped/no_audio", last)
			}
		})
	}
}

// aecGateStub writes an ox-aec fake for the collision test: it drops its report, touches the signal file,
// then holds until the wait file exists before writing its output — so a second run can land in between.
// marker is one letter; it lands in the report's "mark" field and as the output's every byte, so a mixed
// pair is two files that disagree.
func aecGateStub(t *testing.T, marker string, signal, wait string) string {
	t.Helper()
	dir := t.TempDir()
	report := `{"frames":1,"lag_ms":[],"lag_measured":[],"stats":[],"render_active":0.5,` +
		`"diverged":false,"alignment":"measured","mark":"` + marker + `"}`
	body := "printf '%s\\n' '" + report + "' > \"$rep\"\n"
	if signal != "" {
		body += "touch '" + signal + "'\n"
	}
	if wait != "" {
		body += "while [ ! -f '" + wait + "' ]; do sleep 0.05; done\n"
	}
	// marker as an octal byte for tr: the capture is the 5000 tone (writePCM), so every sample maps.
	oct := fmt.Sprintf("%03o", marker[0])
	body += "tr '\\210\\023' '\\" + oct + "\\" + oct + "' < \"$cap\" > \"$out\"\n"
	script := `#!/bin/sh
LC_ALL=C
export LC_ALL
cap= out= rep=
while [ $# -gt 0 ]; do
	case "$1" in
		--capture) cap="$2"; shift 2 ;;
		--render) shift 2 ;;
		--out) out="$2"; shift 2 ;;
		--report) rep="$2"; shift 2 ;;
		*) shift ;;
	esac
done
` + body
	bin := filepath.Join(dir, "ox-aec")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// waitFile holds until path exists or the deadline passes.
func waitFile(t *testing.T, path string) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); ; {
		if _, err := os.Stat(path); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", path)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// Two runs on one meeting, a slow one and a fast one: whichever pair ends up published, me.aec.pcm and
// aec.json come from the SAME run — the report gates the publish, and the publish is one locked step. The
// stubs mark report ("mark" field) and output (every byte) with their letter; a mixed pair fails.
// Mutation: internal/meeting/aec.go RunAECBin, point --out and --report at dir (drop the run directory and
// the publish step) -> RED (the slow run's late output overwrites half of the fast run's pair).
func TestAECRunPublishesAMatchedPair(t *testing.T) {
	dir := t.TempDir()
	writePCM(t, dir, MePCM, 1, 5000)
	writePCM(t, dir, ThemPCM, 1, 5000)
	gates := t.TempDir()
	repDone := filepath.Join(gates, "a-rep-done")
	aGo := filepath.Join(gates, "a-go")
	binA := aecGateStub(t, "A", repDone, aGo) // writes rep A, signals, waits for a-go, writes out A
	binB := aecGateStub(t, "B", "", repDone)  // waits for A's report, writes rep B + out B
	aDone := make(chan error, 1)
	go func() {
		_, err := RunAECBin(context.Background(), binA, dir)
		aDone <- err
	}()
	waitFile(t, repDone)
	if _, err := RunAECBin(context.Background(), binB, dir); err != nil {
		t.Fatalf("the fast run: %v", err)
	}
	if err := os.WriteFile(aGo, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := <-aDone; err != nil {
		t.Fatalf("the slow run: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, AECJSON))
	if err != nil {
		t.Fatalf("no published report: %v", err)
	}
	out, err := os.ReadFile(filepath.Join(dir, MeAECPCM))
	if err != nil {
		t.Fatalf("no published output: %v", err)
	}
	var repMark, outMark string
	if strings.Contains(string(raw), `"mark":"A"`) {
		repMark = "A"
	} else if strings.Contains(string(raw), `"mark":"B"`) {
		repMark = "B"
	}
	if len(out) > 0 {
		outMark = string(out[0])
	}
	if repMark == "" || repMark != outMark {
		t.Fatalf("published report is run %q's, published audio is run %q's: the pair is mixed", repMark, outMark)
	}
}

// What a daemon killed mid-run leaves: the engine's <out>.tmp files inside its run dir, nothing beside the
// recording. The stage's next pass removes the leftover — the runner takes one meeting at a time, so any
// aec-<id> dir present is a dead run's. The temp names come from the engine's own rule (ox-aec.cpp renames
// <out>.tmp and <report>.tmp), derived here from aecFiles so the account cannot drift.
// Mutation: internal/meeting/aec.go aecStage, delete `sweepAECRunDirs(dir, r.Log)` -> RED (the stale run
// directory survives the stage).
func TestAECRunLeftoversAreSwept(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "ok"))
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	stale := filepath.Join(dir, WorkDir, aecRunPrefix+"1")
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range aecFiles {
		writeFile(t, filepath.Join(stale, name+".tmp"), "partial")
	}
	file, _, err := f.r.aecStage(context.Background(), id, dir, newStageLog(f.r.Log, id, f.r.Now))
	if err != nil || file != MeAECPCM {
		t.Fatalf("aecStage = %q %v, want me.aec.pcm", file, err)
	}
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Error("the stale run directory survived the stage")
	}
	if left, _ := filepath.Glob(filepath.Join(dir, WorkDir, aecRunPrefix+"*")); len(left) != 0 {
		t.Errorf("run directories left behind: %v", left)
	}
	if tops, _ := filepath.Glob(filepath.Join(dir, "*.tmp")); len(tops) != 0 {
		t.Errorf("engine temp files at the meeting level: %v", tops)
	}
}

// An engine that writes its temp names and dies: the run dir goes with it, nothing lands beside the
// recording, and the meeting falls back to the raw channel.
// Mutation: internal/meeting/aec.go RunAECBin, delete the `defer` that removes rundir -> RED (the dead run's
// directory survives with its temp files).
func TestAECInterruptedRunLeavesNoAudioCopy(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "tmpfail"))
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	file, warns, err := f.r.aecStage(context.Background(), id, dir, newStageLog(f.r.Log, id, f.r.Now))
	if err != nil || file != MePCM || !slices.Contains(warns, WarnAECFailed) {
		t.Fatalf("aecStage = %q %v %v, want me.pcm with aec_failed", file, warns, err)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, WorkDir, aecRunPrefix+"*")); len(left) != 0 {
		t.Errorf("the dead run's directory survived: %v", left)
	}
	if tops, _ := filepath.Glob(filepath.Join(dir, "*.tmp")); len(tops) != 0 {
		t.Errorf("engine temp files at the meeting level: %v", tops)
	}
	for _, name := range aecFiles {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s published by a run that died mid-write", name)
		}
	}
}

// A run directory the daemon could not clean (killed mid-write) and the published artifacts both go with
// the audio at retention: work/ is retired whole and the aec names are on retiredNames.
// Mutation: internal/meeting/retention.go retiredNames, delete `WorkDir` -> RED (the run dir's temps survive).
func TestAECRunLeftoversGoWithTheAudio(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "ok"))
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	stale := filepath.Join(dir, WorkDir, aecRunPrefix+"1")
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	var temps []string
	for _, name := range aecFiles {
		tmp := filepath.Join(stale, name+".tmp")
		writeFile(t, tmp, "partial")
		temps = append(temps, tmp)
	}
	f.now = f.now.Add(400 * 24 * time.Hour)
	if n := f.r.SweepRetention(); n != 1 {
		t.Fatalf("swept %d meetings, want 1", n)
	}
	for _, p := range temps {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("%s survived the sweep", p)
		}
	}
	for _, name := range []string{MePCM, ThemPCM, MeAECPCM, AECJSON} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s survived the sweep", name)
		}
	}
}

// A later run with the setting off still leaves no audio copy behind: the stage sweeps stale run dirs even
// when the canceller itself never runs, and a finished transcription removes work/ whole.
func TestAECOffRunLeavesNoAudioCopy(t *testing.T) {
	f := newFixture(t) // meeting_aec never turned on
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	stale := filepath.Join(dir, WorkDir, aecRunPrefix+"1")
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range aecFiles {
		writeFile(t, filepath.Join(stale, name+".tmp"), "partial")
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, WorkDir, aecRunPrefix+"*")); len(left) != 0 {
		t.Errorf("run directories left behind: %v", left)
	}
	if tops, _ := filepath.Glob(filepath.Join(dir, "*.tmp")); len(tops) != 0 {
		t.Errorf("engine temp files at the meeting level: %v", tops)
	}
	for _, name := range aecFiles {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s exists after a run with the setting off", name)
		}
	}
}

// The published aec output leaves the backup the way the recorded channels and work/ do: retention deletes
// it on a schedule and Time Machine must not keep a copy.
// Mutation: internal/meeting/aec.go publishAEC, delete the `excludeBackup(out)` call -> RED (the published
// file is not among the marked paths).
func TestAECPublishedAudioIsExcludedFromBackup(t *testing.T) {
	marked := recordExcluded(t)
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "ok"))
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if want := filepath.Join(dir, MeAECPCM); !slices.Contains(*marked, want) {
		t.Fatalf("marked %v, want the published %s among them", *marked, want)
	}
}

// The mic only heard the far side: after cancelling, the channel is silent, but the mic did hear sound, so the
// transcript is made from the cleaned file and the meeting is NOT told it has "no mic audio".
// Mutation: internal/meeting/runner.go transcribe, delete the `speech = r.heardAnything(dir, ch.rawFile())` line ->
// RED (no_mic_audio on a mic that worked).
func TestAECSilencedMicIsNotNoMicAudio(t *testing.T) {
	f := newFixture(t)
	aecOn(t, f)
	f.r.AEC = aecRunner(aecStub(t, "silent"))
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	m := f.load(t, id)
	if slices.Contains(m.Warnings, WarnNoMicAudio) {
		t.Fatalf("warnings = %v: a mic that heard the far side was reported as heard-nothing", m.Warnings)
	}
	if last := f.r.LastAEC(); last == nil || last.Result != stageOK {
		t.Fatalf("LastAEC = %+v, want ok", last)
	}
}
