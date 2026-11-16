package daemon

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// writeMarker writes one model-set revision marker under the daemon's diar models dir.
func writeMarker(t *testing.T, cfg *config.Config, rel, revision string) {
	t.Helper()
	path := filepath.Join(cfg.DiarModelsDir(), filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(revision+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

const (
	oldPyannoteMarker = "speaker-diarization/.fluidaudio-revision" // the set of the removed pyannote engine
	oldPyannoteRev    = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
	nemotronMarker    = "nemotron-3-diarization/.ox-say-revision"
)

func asAppleSilicon15(t *testing.T) {
	t.Helper()
	was, wasArch := osMajor, goArch
	t.Cleanup(func() { osMajor, goArch = was, wasArch })
	goArch = "arm64"
	osMajor = func() (int, bool) { return 15, true }
}

// diarReady asks for the Nemotron set and nothing else: a Mac that has only the set of the removed pyannote engine is
// not ready (models_missing: the updater fetches the Nemotron set before it swaps the engine, so this is the Mac that
// has not finished an update), and a Mac with the Nemotron set is ready whether or not the old folder is still there.
// Mutation: internal/daemon/diarize.go diarReady, delete the `!d.Cfg.DiarModelsReady()` branch (always ready) -> RED on
// the first row; internal/config/config.go DiarModelsReady, read the speaker-diarization marker -> RED on both rows.
func TestDiarReadyAsksForTheNemotronSetOnly(t *testing.T) {
	asAppleSilicon15(t)
	for _, tc := range []struct {
		marker string
		rev    string
		want   string
	}{
		{oldPyannoteMarker, oldPyannoteRev, meeting.DiarModelsMissing},
		{nemotronMarker, config.NemotronModelsRevision, ""},
	} {
		home := t.TempDir()
		cfg := &config.Config{Home: home, DiarBin: filepath.Join(home, "ox-diar")}
		if err := os.WriteFile(cfg.DiarBin, []byte("x"), 0o755); err != nil {
			t.Fatal(err)
		}
		writeMarker(t, cfg, tc.marker, tc.rev)
		if got := (&Daemon{Cfg: cfg}).diarReady(); got != tc.want {
			t.Errorf("with only %s: diarReady = %q, want %q", tc.marker, got, tc.want)
		}
	}
}

// A Mac whose LaunchAgent still says OX_SAY_DIAR_ENGINE=pyannote (an override an earlier release honoured, carried over
// by the installer on every update) runs the one engine there is: the daemon loads its config without a complaint, finds
// the Nemotron set ready, and starts ox-diar with the contract arguments and no engine flag. The stub fails the run (exit 9)
// on anything but `<pcm> <out> --models <dir>`, so a daemon that forwarded the stale value, or any engine name, is seen.
// Mutation: internal/daemon/diarize.go runDiarizer, append `"--engine", os.Getenv("OX_SAY_DIAR_ENGINE")` to the args ->
// RED (the stub is given six arguments and the run fails); internal/config/config.go load, return an error when
// OX_SAY_DIAR_ENGINE is set -> RED (the config does not load).
func TestAStaleDiarEngineSettingRunsTheOneEngine(t *testing.T) {
	asAppleSilicon15(t)
	for _, stale := range []string{"pyannote", "PYANNOTE ", "nemotron", "nemotorn"} {
		t.Run(stale, func(t *testing.T) {
			stub, pcm := stubDiar(t, `
[ "$#" = 4 ] && [ "$3" = "--models" ] || { echo "args: $*" >&2; exit 9; }
printf '{"version":1,"duration_s":1,"speakers":[],"segments":[]}' > "$2"
`)
			t.Setenv("OX_SAY_HOME", stub.Home)
			t.Setenv("OX_SAY_DIAR_BIN", stub.DiarBin)
			t.Setenv("OX_SAY_DIAR_ENGINE", stale)
			cfg, err := config.Load(nil)
			if err != nil {
				t.Fatalf("a LaunchAgent with OX_SAY_DIAR_ENGINE=%q stopped the daemon: %v", stale, err)
			}
			writeMarker(t, cfg, nemotronMarker, config.NemotronModelsRevision) // the set an update fetches first
			d := &Daemon{Cfg: cfg}
			if got := d.diarReady(); got != "" {
				t.Fatalf("diarReady = %q, want ready on the Nemotron set", got)
			}
			if _, err := runDiarizer(t.Context(), cfg, pcm); err != nil {
				t.Fatalf("OX_SAY_DIAR_ENGINE=%q: %v", stale, err)
			}
		})
	}
}

// The journey of a Mac that has not fetched the Nemotron set yet (an install that updated from the pyannote release has
// only the old set): the meeting finishes with one far-side label and the reason models_missing; a voices retry is
// refused while the set is missing (voices_not_ready, so the app shows the reason and no "Try Again"); after the fetch
// the same retry is accepted, ox-diar is started, the voices come out, and the voiceprint file is gone.
// Mutation: internal/daemon/meetings.go initMeetings, change `DiarizeReady: d.diarReady` to `DiarizeReady: func()
// string { return "" }` -> RED (the meeting is sent to ox-diar without models, and the retry is not refused);
// internal/daemon/diarize.go diarReady, delete the `!d.Cfg.DiarModelsReady()` branch -> RED (F4).
func TestMacOnNemotronWithoutTheSetSaysModelsMissingAndWorksAfterAFetch(t *testing.T) {
	asAppleSilicon15(t)
	stub := `
[ "$#" = 4 ] || { echo "args: $*" >&2; exit 9; }
printf 'ran' >> "$(dirname "$2")/../ox-diar-ran"
printf '{"version":1,"duration_s":15,"speakers":[{"id":0,"speech_s":60},{"id":1,"speech_s":50},{"id":2,"speech_s":46}],"segments":[{"s":0,"e":5,"spk":0},{"s":5,"e":10,"spk":1},{"s":10,"e":16,"spk":2}]}' > "$2"
`
	stubCfg, _ := stubDiar(t, stub)
	d, mux := meetingFixture(t, func(c *config.Config) { c.DiarBin = stubCfg.DiarBin })
	writeMarker(t, d.Cfg, oldPyannoteMarker, oldPyannoteRev) // the old set only

	rec := call(t, mux, "POST", "/v1/meetings", `{"title":"Plan","labels":{"me":"Anatoly","them":"Other","speaker":"Speaker"}}`)
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	writeTone(t, filepath.Join(created.Dir, meeting.MePCM), 20)
	writeTone(t, filepath.Join(created.Dir, meeting.ThemPCM), 20)
	if _, err := d.Meet.Store.Update(created.ID, func(m *meeting.Manifest) { m.Status = meeting.StatusQueued }); err != nil {
		t.Fatal(err)
	}
	ran := filepath.Join(created.Dir, "ox-diar-ran")

	if err := d.Meet.Process(t.Context(), created.ID); err != nil {
		t.Fatal(err)
	}
	m := meetingManifest(t, d, created.ID)
	if len(m.Warnings) != 1 || m.Warnings[0] != meeting.WarnDiarUnavailable || m.DiarReason != meeting.DiarModelsMissing {
		t.Fatalf("without the set: warnings %v reason %q, want diarization_unavailable / models_missing", m.Warnings, m.DiarReason)
	}
	if _, err := os.Stat(ran); err == nil {
		t.Fatal("ox-diar was started without its models")
	}

	rec = call(t, mux, "POST", "/v1/meetings/"+created.ID+"/voices", "")
	var body struct{ Error struct{ Code, Reason string } }
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if rec.Code != http.StatusServiceUnavailable || body.Error.Code != "voices_not_ready" || body.Error.Reason != meeting.DiarModelsMissing {
		t.Fatalf("retry before the fetch = %d %s", rec.Code, rec.Body)
	}

	writeMarker(t, d.Cfg, nemotronMarker, config.NemotronModelsRevision) // the fetch finished

	if rec = call(t, mux, "POST", "/v1/meetings/"+created.ID+"/voices", ""); rec.Code != http.StatusAccepted {
		t.Fatalf("retry after the fetch = %d %s", rec.Code, rec.Body)
	}
	if err := d.Meet.Process(t.Context(), created.ID); err != nil {
		t.Fatal(err)
	}
	m = meetingManifest(t, d, created.ID)
	if len(m.Warnings) != 0 || m.Voices != 3 || m.VoiceMode != meeting.VoicesAuto || m.DiarReason != "" {
		t.Fatalf("after the fetch: warnings %v voices %d mode %q reason %q", m.Warnings, m.Voices, m.VoiceMode, m.DiarReason)
	}
	if _, err := os.Stat(ran); err != nil {
		t.Error("ox-diar was not started after the fetch")
	}
	if _, err := os.Stat(filepath.Join(created.Dir, meeting.WorkDir, meeting.DiarizationJSON)); err == nil {
		t.Error("work/diarization.json (the voiceprint file) was left behind")
	}
}
