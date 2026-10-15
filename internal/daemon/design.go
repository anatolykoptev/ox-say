package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

const (
	defaultDesignTakes = 3
	maxDesignTakes     = 4
	maxDesignText      = 300
	// designSubdir is where design takes live inside the cache dir. A take path
	// a client sends back is confined to it.
	designSubdir = "design"
	// takeStampLayout makes two designs of the same description in one second
	// distinct file names.
	takeStampLayout = "20060102-150405.000"
	takeExt         = ".wav"
	takeMetaExt     = ".json"
	secondsRound    = 100 // durations are reported to 10 ms
	maxDesignBody   = 1 << 20
)

// DesignInput asks VoxCPM2 for a voice from a description alone.
type DesignInput struct {
	Description string `json:"description" jsonschema:"Describe the speaker: gender, age, pitch, timbre, pace, accent or native language, mood, use (max 300 chars). Example: A clear, pleasant female narrator in her thirties, native Russian speaker, friendly and professional"`
	Text        string `json:"text" jsonschema:"1-2 sentences in the target language, 5-15 s spoken (max 300 chars); it is also the saved voice's transcript"`
	Takes       int    `json:"takes,omitempty" jsonschema:"How many candidate takes, 1-4 (default 3)"`
	Seed        *int64 `json:"seed,omitempty" jsonschema:"Seed of the first take; the others use the next seeds. Same seed, same take"`
}

// DesignTake is one rendered candidate.
type DesignTake struct {
	Path      string  `json:"path"`
	Seed      int64   `json:"seed"`
	DurationS float64 `json:"duration_s"`
}

// DesignResult lists the takes and how to keep one.
type DesignResult struct {
	Description string       `json:"description"`
	Text        string       `json:"text"`
	Takes       []DesignTake `json:"takes"`
	SaveHint    string       `json:"save_hint"`
}

// designRecord is the daemon's own note beside each take (<take>.json). The
// saved voice's transcript, description and seed come from here, never from the
// save request, so a client cannot make a voice claim a provenance it lacks.
type designRecord struct {
	Description string `json:"description"`
	Text        string `json:"text"`
	Seed        int64  `json:"seed"`
}

// SaveDesignInput keeps one take under a voice name.
type SaveDesignInput struct {
	Name string `json:"name" jsonschema:"Voice name: ^[a-z0-9][a-z0-9_-]{0,31}$"`
	Take string `json:"take" jsonschema:"The path of a take returned by voice_design"`
}

// SaveDesignResult is the saved voice.
type SaveDesignResult struct {
	Name               string `json:"name"`
	Engine             string `json:"engine"`
	DesignedFrom       string `json:"designed_from"`
	Seed               int64  `json:"seed"`
	RegisteredToEngine bool   `json:"registered_to_engine"`
	Notice             string `json:"notice,omitempty"`
}

func (in *DesignInput) validate(seedRange int64) error {
	switch {
	case sanitizeStyle(in.Description) == "":
		return &requestError{"description is required: say who is speaking, e.g. \"a warm young woman, smiling voice\""}
	case utf8.RuneCountInString(in.Description) > maxStyleChars:
		return &requestError{fmt.Sprintf("description is longer than %d characters", maxStyleChars)}
	case strings.TrimSpace(in.Text) == "":
		return &requestError{"text is required: one or two sentences in the voice's language"}
	case utf8.RuneCountInString(in.Text) > maxDesignText:
		return &requestError{fmt.Sprintf("text is longer than %d characters", maxDesignText)}
	case in.Takes < 0 || in.Takes > maxDesignTakes:
		return &requestError{fmt.Sprintf("takes must be 1..%d", maxDesignTakes)}
	case in.Seed != nil && (*in.Seed < 0 || *in.Seed > seedRange):
		return &requestError{fmt.Sprintf("seed must be 0..%d so every take has a valid seed", seedRange)}
	}
	return nil
}

// designDir is the one directory design takes are written to and read from.
func (d *Daemon) designDir() string { return filepath.Join(d.Cfg.CacheDir, designSubdir) }

// DesignVoice renders in.Takes candidate clips of in.Text in a voice described
// by in.Description, with consecutive seeds from in.Seed (or a random base).
// No voice takes part — not even the configured default — and the description
// is the style tag, sanitised by the adapter. Takes are previews and stay at the
// engine's own level (no loudness normalisation). Keep one with SaveDesignedVoice.
func (d *Daemon) DesignVoice(ctx context.Context, in DesignInput) (*DesignResult, error) {
	takes := in.Takes
	if takes == 0 {
		takes = defaultDesignTakes
	}
	if err := in.validate(maxVoxSeed - int64(takes) + 1); err != nil {
		return nil, err
	}
	in.Takes = takes
	if why := d.voxUnavailable(); why != "" {
		return nil, &unavailableError{why}
	}
	if err := os.MkdirAll(d.designDir(), 0o755); err != nil {
		return nil, err
	}
	base := min(randomSeed(), maxVoxSeed-int64(takes)+1)
	if in.Seed != nil {
		base = *in.Seed
	}
	stamp := time.Now().Format(takeStampLayout)
	res := &DesignResult{Description: in.Description, Text: in.Text}
	for i := range takes {
		take, err := d.designTake(ctx, in, stamp, base+int64(i))
		if err != nil {
			return nil, err
		}
		res.Takes = append(res.Takes, *take)
	}
	res.SaveHint = "keep a take with: ox-say voice save <name> <take path>   (MCP: voice_design_save {name, take})"
	return res, nil
}

// designTake renders one take and writes it and its record.
func (d *Daemon) designTake(ctx context.Context, in DesignInput, stamp string, seed int64) (*DesignTake, error) {
	out, err := d.render(ctx, map[string]any{
		fieldModel: config.TTSModelVoxCPM2, fieldInput: in.Text, fieldInstruct: in.Description,
		fieldVoice: "default", fieldSeed: seed,
	})
	if err != nil {
		return nil, err
	}
	stem := filepath.Join(d.designDir(), fmt.Sprintf("%s-%s-%d", stamp, slugify(in.Description), seed))
	if err := writeFile(stem+takeExt, out.WAV, false); err != nil {
		return nil, err
	}
	rec, err := json.Marshal(designRecord{Description: in.Description, Text: in.Text, Seed: seed})
	if err == nil {
		err = writeFile(stem+takeMetaExt, rec, false)
	}
	if err != nil {
		if rerr := os.Remove(stem + takeExt); rerr != nil {
			d.log.Warn("design: cannot remove a take left without its record", slog.String("path", stem+takeExt), slog.Any("error", rerr))
		}
		return nil, err
	}
	return &DesignTake{Path: stem + takeExt, Seed: seed, DurationS: math.Round(wavDuration(out.WAV)*secondsRound) / secondsRound}, nil
}

// errNotATake is the refusal for any path that is not a take this daemon made.
func errNotATake(why string) error {
	return &requestError{"that is not a take made by voice design (" + why + "): pass a path returned by voice design"}
}

// resolveTake confines a client-supplied path to the design dir and returns the
// real path of the take and its record. Every component is resolved first, so
// "..", a symlinked file and a symlinked directory all end up outside the
// prefix check; the take and the record themselves must not be symlinks.
func (d *Daemon) resolveTake(path string) (take string, rec designRecord, err error) {
	switch {
	case path == "" || !filepath.IsAbs(path):
		return "", rec, errNotATake("the path must be absolute")
	case !strings.EqualFold(filepath.Ext(path), takeExt):
		return "", rec, errNotATake("it is not a .wav file")
	}
	root, err := filepath.EvalSymlinks(d.designDir())
	if err != nil {
		return "", rec, errNotATake("no takes have been made yet")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", rec, errNotATake("no such file")
	}
	if rel, rerr := filepath.Rel(root, resolved); rerr != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", rec, errNotATake("it is outside the takes folder")
	}
	recPath := strings.TrimSuffix(resolved, filepath.Ext(resolved)) + takeMetaExt
	for _, p := range []string{resolved, recPath} {
		if st, serr := os.Lstat(p); serr != nil || !st.Mode().IsRegular() {
			return "", rec, errNotATake("it is not one of the daemon's own files")
		}
	}
	raw, err := readCapped(recPath, maxDesignBody)
	if err != nil || json.Unmarshal(raw, &rec) != nil || strings.TrimSpace(rec.Text) == "" {
		return "", rec, errNotATake("its record is missing")
	}
	return resolved, rec, nil
}

// readCapped reads a small file, refusing one larger than limit.
func readCapped(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fs.ErrInvalid
	}
	return b, nil
}

// SaveDesignedVoice keeps a design take as a named voxcpm2 voice: the take is
// the reference, its text the transcript, and the description and seed come
// from the daemon's record of the take. The ordinary add path then enforces the
// reference window (a take past it is refused in plain words, nothing stored).
func (d *Daemon) SaveDesignedVoice(ctx context.Context, in SaveDesignInput) (*voices.Voice, bool, error) {
	if strings.TrimSpace(in.Take) == "" {
		return nil, false, &requestError{"take is required: the path of a take returned by voice design"}
	}
	take, rec, err := d.resolveTake(in.Take)
	if err != nil {
		return nil, false, err
	}
	seed := rec.Seed
	return d.AddVoiceMeta(ctx, in.Name, take, rec.Text, voices.Meta{
		Engine: config.TTSModelVoxCPM2, DesignedFrom: rec.Description, Seed: &seed,
	})
}

func (d *Daemon) handleDesignVoice(w http.ResponseWriter, r *http.Request) {
	var in DesignInput
	if err := json.NewDecoder(io.LimitReader(r.Body, maxDesignBody)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	res, err := d.DesignVoice(r.Context(), in)
	if err != nil {
		writeErr(w, synthStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (d *Daemon) handleSaveDesign(w http.ResponseWriter, r *http.Request) {
	// Only name and take are read: any other field a client sends is ignored.
	var in SaveDesignInput
	if err := json.NewDecoder(io.LimitReader(r.Body, maxDesignBody)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	res, err := d.saveDesignResult(r.Context(), in)
	if err != nil {
		writeErr(w, synthStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// saveDesignResult is SaveDesignedVoice shaped for the HTTP and MCP answers.
func (d *Daemon) saveDesignResult(ctx context.Context, in SaveDesignInput) (*SaveDesignResult, error) {
	v, registered, err := d.SaveDesignedVoice(ctx, in)
	if err != nil {
		return nil, err
	}
	if v.Seed == nil {
		return nil, errors.New("saved voice has no seed")
	}
	return &SaveDesignResult{
		Name: v.Name, Engine: v.Engine, DesignedFrom: v.DesignedFrom, Seed: *v.Seed,
		RegisteredToEngine: registered, Notice: v.Notice,
	}, nil
}
