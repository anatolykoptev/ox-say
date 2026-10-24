package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// stubDiar writes an executable shell script standing in for ox-diar and a one-second channel file in a meeting
// directory laid out as the runner lays it out.
func stubDiar(t *testing.T, body string) (*config.Config, string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "ox-diar")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	meetingDir := filepath.Join(dir, "meetings", "m1")
	if err := os.MkdirAll(meetingDir, 0o700); err != nil {
		t.Fatal(err)
	}
	pcm := filepath.Join(meetingDir, meeting.ThemPCM)
	if err := os.WriteFile(pcm, make([]byte, 64000), 0o600); err != nil {
		t.Fatal(err)
	}
	return &config.Config{Home: dir, DiarBin: bin}, pcm
}

// The CLI contract: <them.pcm> <out.json> --models <models>/diar. ox-diar is given the meeting's own channel file
// (no copy of the audio is made anywhere), the answer is read from <out.json> inside work/ and is not left behind.
// The stub checks what ox-diar would depend on.
// Mutations: internal/daemon/diarize.go runDiarizer, change `"--models", cfg.DiarModelsDir()` to `"--models", out`
// -> RED; change `[]string{pcmPath, out,` to `[]string{out, out,` -> RED (the stub is not given the channel).
func TestRunDiarizerPassesTheContractAndReadsTheResult(t *testing.T) {
	cfg, pcm := stubDiar(t, `
in=$1; out=$2
[ "$3" = "--models" ] || { echo "no --models: $*" >&2; exit 2; }
case "$4" in */models/diar) ;; *) echo "bad models dir $4" >&2; exit 3;; esac
case "$in" in */them.pcm) ;; *) echo "not the channel file: $in" >&2; exit 4;; esac
case "$out" in */work/diarization.json) ;; *) echo "answer outside work/: $out" >&2; exit 4;; esac
printf '{"size":%s}' "$(wc -c < "$in" | tr -d ' ')" > "$out"
`)
	raw, err := runDiarizer(context.Background(), cfg, pcm)
	if err != nil || string(raw) != `{"size":64000}` {
		t.Fatalf("raw %q err %v", raw, err)
	}
	left, _ := os.ReadDir(filepath.Join(filepath.Dir(pcm), meeting.WorkDir))
	if len(left) != 0 {
		t.Errorf("files left in work/: %v", left)
	}
}

// ox-diar's own refusal on an old macOS, and models that will not load, are "not available", not failures (a retry
// would transcribe the call again for nothing); any other exit is an error carrying ox-diar's last words.
// Mutations: internal/daemon/diarize.go, change `diarExitUnsupportedOS = 5` to `6` -> RED (the refusal reads as a
// failure); change `diarExitModels = 3` to `4` -> RED (models that will not load read as a failure).
func TestRunDiarizerMapsTheExitCodes(t *testing.T) {
	cfg, pcm := stubDiar(t, `echo "ox-diar needs macOS 15 or later" >&2; exit 5`)
	_, err := runDiarizer(context.Background(), cfg, pcm)
	var un *meeting.DiarUnavailableError
	if !errors.As(err, &un) || un.Reason != meeting.DiarOSTooOld {
		t.Fatalf("exit 5: %v", err)
	}
	cfg, pcm = stubDiar(t, `echo "cannot load the models" >&2; exit 3`)
	_, err = runDiarizer(context.Background(), cfg, pcm)
	if !errors.As(err, &un) || un.Reason != meeting.DiarModelsUnusable || !strings.Contains(un.Detail, "cannot load the models") {
		t.Fatalf("exit 3: %v", err)
	}
	cfg, pcm = stubDiar(t, `echo "boom" >&2; exit 1`)
	if _, err = runDiarizer(context.Background(), cfg, pcm); err == nil || !strings.Contains(err.Error(), "boom") || errors.As(err, &un) {
		t.Fatalf("exit 1: %v", err)
	}
}

func TestRunDiarizerRefusesAnExitWithoutAResult(t *testing.T) {
	cfg, pcm := stubDiar(t, `exit 0`)
	if _, err := runDiarizer(context.Background(), cfg, pcm); err == nil || !strings.Contains(err.Error(), "without writing") {
		t.Fatalf("err = %v", err)
	}
}

// A cancel (the daemon stopping) kills the child and returns the context's error, not a failure.
// Mutation: internal/oneshot/oneshot.go, change `exec.CommandContext(ctx, bin, args...)` to `exec.Command(bin, args...)`
// -> RED (this test runs the stub's 30 s sleep out).
func TestRunDiarizerStopsWhenCancelled(t *testing.T) {
	cfg, pcm := stubDiar(t, `sleep 30`)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := runDiarizer(ctx, cfg, pcm)
	if err == nil || ctx.Err() == nil || time.Since(start) > 15*time.Second {
		t.Fatalf("err %v after %v", err, time.Since(start))
	}
}

// diarReady names what is missing, in the order that matters: an old (or unreadable) macOS first, then the CPU, then
// the engine, then the models.
// Mutation: internal/daemon/diarize.go diarReady, change `major < diarMinMacOS` to `major < 14` -> RED (macOS 14 is let through).
func TestDiarReady(t *testing.T) {
	home := t.TempDir()
	cfg := &config.Config{Home: home, DiarBin: filepath.Join(home, "ox-diar")}
	d := &Daemon{Cfg: cfg}
	was, wasArch := osMajor, goArch
	t.Cleanup(func() { osMajor, goArch = was, wasArch })
	goArch = "arm64"
	osMajor = func() (int, bool) { return 14, true }
	if got := d.diarReady(); got != meeting.DiarOSTooOld {
		t.Fatalf("macOS 14: %q", got)
	}
	osMajor = func() (int, bool) { return 15, true }
	if got := d.diarReady(); got != meeting.DiarEngineMissing {
		t.Fatalf("no engine: %q", got)
	}
	if err := os.WriteFile(cfg.DiarBin, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := d.diarReady(); got != meeting.DiarModelsMissing {
		t.Fatalf("no models: %q", got)
	}
	marker := filepath.Join(cfg.DiarModelsDir(), "speaker-diarization", ".fluidaudio-revision")
	if err := os.MkdirAll(filepath.Dir(marker), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(marker, []byte(config.DiarModelsRevision+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := d.diarReady(); got != "" {
		t.Fatalf("everything there: %q", got)
	}
}

// A system that will not say its version fails CLOSED: a macOS 13 Mac cannot even launch the minos-14.0 binary, so
// falling through to exec would be a crash, not a degraded meeting.
// Mutation: internal/daemon/diarize.go diarReady, change `if major, ok := osMajor(); !ok || major < diarMinMacOS` to
// `if major, ok := osMajor(); ok && major < diarMinMacOS` -> RED.
func TestDiarReadyFailsClosedWhenTheOSVersionIsUnknown(t *testing.T) {
	home := t.TempDir()
	cfg := &config.Config{Home: home, DiarBin: filepath.Join(home, "ox-diar")}
	if err := os.WriteFile(cfg.DiarBin, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Cfg: cfg}
	was, wasArch := osMajor, goArch
	t.Cleanup(func() { osMajor, goArch = was, wasArch })
	goArch = "arm64"
	osMajor = func() (int, bool) { return 0, false }
	if got := d.diarReady(); got != meeting.DiarOSTooOld {
		t.Fatalf("unknown macOS: %q, want %q", got, meeting.DiarOSTooOld)
	}
}

// On an Intel Mac the diarizer is not offered (the Intel smoke of plan Task 20a failed), whatever is installed.
// Mutation: internal/daemon/diarize.go diarReady, change `goArch == "amd64"` to `false` -> RED.
func TestDiarReadyOnIntel(t *testing.T) {
	home := t.TempDir()
	d := &Daemon{Cfg: &config.Config{Home: home, DiarBin: filepath.Join(home, "ox-diar")}}
	was, wasArch := osMajor, goArch
	t.Cleanup(func() { osMajor, goArch = was, wasArch })
	osMajor = func() (int, bool) { return 15, true }
	goArch = "amd64"
	if got := d.diarReady(); got != meeting.DiarCPUUnsupported {
		t.Fatalf("Intel: %q", got)
	}
	goArch = "arm64"
	if got := d.diarReady(); got != meeting.DiarEngineMissing {
		t.Fatalf("Apple Silicon: %q", got)
	}
}

// ox-diar holds the whole channel in memory (about 1.06 GB resident per hour of audio), so a recording longer than
// diarMaxSeconds is not given to it: "unavailable" (too_long), not a failure, and the engine is never started. A
// recording of exactly the cap still runs.
// Mutations: internal/daemon/diarize.go runDiarizer, change `st.Size() > diarMaxPCMBytes` to `false` -> RED (the stub
// is started and the error is not the unavailable one); change `>` to `>=` -> RED (the recording of exactly the cap
// is refused).
func TestRunDiarizerSkipsARecordingAboveTheSizeCap(t *testing.T) {
	cfg, pcm := stubDiar(t, `printf 'started' > "$(dirname "$2")/../ran"; printf '{}' > "$2"`)
	ran := filepath.Join(filepath.Dir(pcm), "ran")
	if err := os.Truncate(pcm, diarMaxPCMBytes+1); err != nil {
		t.Fatal(err)
	}
	_, err := runDiarizer(context.Background(), cfg, pcm)
	var un *meeting.DiarUnavailableError
	if !errors.As(err, &un) || un.Reason != meeting.DiarTooLong {
		t.Fatalf("over the cap: %v", err)
	}
	if _, serr := os.Stat(ran); serr == nil {
		t.Error("ox-diar was started for a recording over the cap")
	}
	if err := os.Truncate(pcm, diarMaxPCMBytes); err != nil {
		t.Fatal(err)
	}
	if _, err := runDiarizer(context.Background(), cfg, pcm); err != nil {
		t.Fatalf("exactly the cap: %v", err)
	}
	if _, serr := os.Stat(ran); serr != nil {
		t.Error("ox-diar was not started for a recording of exactly the cap")
	}
}

// The numbers that must be the same in two languages are compared, read from the source of the other side:
// the models revision (fetch-models.sh, Pins.swift, config), the oldest macOS and ox-diar's two exit codes.
// Mutations: scripts/fetch-models.sh, change `diar_rev=` to another revision -> RED; engine/diar/Sources/OxDiarCore/
// Platform.swift, change `minimumMajor = 15` to `14` -> RED; engine/diar/Sources/OxDiarCore/Platform.swift, change
// `case unsupportedOS = 5` to `= 6` -> RED.
func TestDiarPinsAgreeAcrossLanguages(t *testing.T) {
	_, here, _, _ := runtime.Caller(0)
	root := filepath.Join(filepath.Dir(here), "..", "..")
	read := func(rel string) string {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	find := func(rel, pattern string) string {
		t.Helper()
		m := regexp.MustCompile(pattern).FindStringSubmatch(read(rel))
		if m == nil {
			t.Fatalf("%s: no match for %s", rel, pattern)
		}
		return m[1]
	}
	if got := find("scripts/fetch-models.sh", `(?m)^diar_rev=([0-9a-f]{40})$`); got != config.DiarModelsRevision {
		t.Errorf("fetch-models.sh fetches %s, config expects %s", got, config.DiarModelsRevision)
	}
	if got := find("engine/diar/Sources/OxDiarCore/Pins.swift", `modelsRevision = "([0-9a-f]{40})"`); got != config.DiarModelsRevision {
		t.Errorf("Pins.swift names %s, config expects %s", got, config.DiarModelsRevision)
	}
	if got := find("engine/diar/Sources/OxDiarCore/Platform.swift", `minimumMajor = (\d+)`); got != "15" || diarMinMacOS != 15 {
		t.Errorf("minimumMajor %s, diarMinMacOS %d", got, diarMinMacOS)
	}
	if got := find("engine/diar/Sources/OxDiarCore/Platform.swift", `case unsupportedOS = (\d+)`); got != "5" || diarExitUnsupportedOS != 5 {
		t.Errorf("unsupportedOS %s, diarExitUnsupportedOS %d", got, diarExitUnsupportedOS)
	}
	if got := find("engine/diar/Sources/OxDiarCore/Platform.swift", `case models = (\d+)`); got != "3" || diarExitModels != 3 {
		t.Errorf("models %s, diarExitModels %d", got, diarExitModels)
	}
	// the lists in fetch-models.sh name 24 model files and 4 documents, each with a 64-hex SHA-256
	if n := len(regexp.MustCompile(`(?m)^    "[0-9a-f]{64}  \S+"$`).FindAllString(read("scripts/fetch-models.sh"), -1)); n != 28 {
		t.Errorf("fetch-models.sh lists %d diarization entries, want 28", n)
	}
}

// A diarizer killed mid-run (a timeout, the daemon stopping, a crash) leaves nothing of the call outside work/: the
// meeting directory holds the channel file and work/, and whatever ox-diar had written is under work/, which goes
// with the audio. (The leak this guards against is the engine's own: see engine/diar/test_cli.py, which kills the
// real binary.)
// Mutation: internal/daemon/diarize.go runDiarizer, change `out := filepath.Join(work, meeting.DiarizationJSON)` to
// `out := filepath.Join(filepath.Dir(pcmPath), meeting.DiarizationJSON)` -> RED.
func TestAKilledDiarizerLeavesNothingOutsideWork(t *testing.T) {
	cfg, pcm := stubDiar(t, `
printf 'voiceprint' > "$(dirname "$2")/partial.tmp"  # what ox-diar's atomic write leaves beside its answer
printf 'voiceprint' > "$2"
sleep 30
`)
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if _, err := runDiarizer(ctx, cfg, pcm); err == nil {
		t.Fatal("a killed run reported success")
	}
	dir := filepath.Dir(pcm)
	err := filepath.WalkDir(dir, func(path string, e os.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(dir, path)
		if rel != meeting.ThemPCM && !strings.HasPrefix(rel, meeting.WorkDir+string(filepath.Separator)) {
			t.Errorf("%s was left outside work/", rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
