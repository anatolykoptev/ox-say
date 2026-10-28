package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/sys/unix"

	"github.com/anatolykoptev/ox-say/internal/vproject"
	"github.com/anatolykoptev/ox-say/internal/vscript"
)

const (
	opPick       = "pick"
	opRegenerate = "regenerate"
	opEdit       = "edit"
	opDelivery   = "delivery"
	titleRunes   = 60
	// maxSupersededTakes bounds Chunk.Superseded: the takes a delivery change
	// replaced stay cached for a revert, but disk stays bounded. Two earlier
	// variants of a maximum-take chunk are kept whole.
	maxSupersededTakes = 2 * maxTakesPerChunk
	// deliveryNeedsReference refuses a delivery that would move an auto-mode
	// job's clone mode: styling one phrase on an ultimate job would re-render
	// them all in reference mode.
	deliveryNeedsReference = "styling a phrase needs clone_mode reference; create the project with clone_mode reference (ox-say produce --clone-mode reference)"
	// deliveryIsUltimate refuses a style on a job pinned to clone_mode
	// ultimate at create: no style can ever apply there.
	deliveryIsUltimate = "styling a phrase cannot apply: the project was created with clone_mode ultimate"
	// takesMargin is the factor of takes kept on disk per planned take, with
	// room for retries, in the free-space estimate.
	takesMargin = 1.3
	// outputCopies counts the copies of the audio on disk at once besides the
	// takes: the assembled temp, the normalised file and the published WAV.
	outputCopies = 3
	bytesPerGB   = 1e9
)

// chunkOp changes one chunk of a project that is not running.
type chunkOp struct {
	Action     string
	Takes      int
	Take       string
	Text       string
	Style      *string
	PauseAfter *float64
	Pace       *float64
}

// deliveryEntry is one chunk's part of a delivery request: a nil field
// leaves the chunk alone, so a batch mixes style and pause changes.
type deliveryEntry struct {
	N          *int     `json:"n" jsonschema:"Chunk index, 0-based (see produce_status chunks)"`
	Style      *string  `json:"style,omitempty" jsonschema:"New delivery for the chunk, e.g. excited, lively; \"\" clears it to the project default"`
	PauseAfter *float64 `json:"pause_after,omitempty" jsonschema:"Silence after the chunk in seconds; 0 clears it, otherwise the range a [pause Ns] directive takes"`
	Pace       *float64 `json:"pace,omitempty" jsonschema:"Speech rate multiplier, 0.85-1.15 (0.9 slower, 1.1 faster); 0 restores neutral. Needs ffmpeg's atempo filter on this machine"`
}

// create validates in, writes a new project and launches it.
func (p *producer) create(in produceInput) (vproject.Summary, error) {
	if err := p.ready(); err != nil {
		return vproject.Summary{}, err
	}
	if why := p.ports.Unavailable(); why != "" {
		return vproject.Summary{}, &unavailableError{why}
	}
	m, err := p.newManifest(in)
	if err != nil {
		return vproject.Summary{}, err
	}
	p.mu.Lock()
	busy := p.cur
	p.mu.Unlock()
	if busy != nil {
		return vproject.Summary{}, &busyError{busy.m.ID}
	}
	dir, err := p.makeProject(m, in.Script)
	if err != nil {
		return vproject.Summary{}, err
	}
	j := &job{dir: dir, m: m, regen: map[int]int{}}
	j.allowBattery.Store(in.AllowBattery)
	s, err := p.launch(j)
	if err != nil {
		p.discard(dir) // a project that never ran is not kept
	}
	return s, err
}

// discard removes a project directory that was just created and never ran.
func (p *producer) discard(dir string) {
	if vproject.Contained(p.root, dir) == nil {
		if err := os.RemoveAll(dir); err != nil {
			p.log.Warn("produce: cannot remove an unused project", slog.Any("error", err))
		}
	}
}

// newManifest validates everything a create can check without the disk
// being written.
func (p *producer) newManifest(in produceInput) (*vproject.Manifest, error) {
	name := in.Preset
	if name == "" {
		name = defaultPreset
	}
	pr, ok := presets[name]
	if !ok {
		return nil, &requestError{fmt.Sprintf("preset %q: want youtube, reels or voice-under-music", in.Preset)}
	}
	if n := utf8.RuneCountInString(in.Script); n == 0 || n > maxProduceChars {
		return nil, &requestError{fmt.Sprintf("the script must have 1–%d characters (about 48 minutes of speech); it has %d", maxProduceChars, n)}
	}
	chunks, err := vscript.Parse(in.Script, pr.opts)
	if err != nil {
		return nil, &requestError{err.Error()}
	}
	voice := in.Voice
	if voice == "" {
		voice = p.ports.DefaultVoice(langOfText(in.Script))
	}
	if voice == "" {
		return nil, &requestError{"produce needs a saved voice: design one with voice_design or add one with voice_add"}
	}
	facts, err := p.ports.Voice(voice)
	if err != nil {
		return nil, err
	}
	style := vscript.CleanStyle(in.Style)
	if utf8.RuneCountInString(style) > vscript.MaxStyleChars {
		return nil, &requestError{fmt.Sprintf("style is longer than %d characters", vscript.MaxStyleChars)}
	}
	// clone_mode is judged by the adapter's own validator against every
	// chunk: an invalid value, or ultimate with any style, fails the create.
	if _, _, err := jobCloneMode(facts, style, chunks, in.CloneMode); err != nil {
		return nil, err
	}
	takes := in.Takes
	if takes == 0 {
		takes = pr.takes
	}
	if takes < 1 || takes > maxTakesPerChunk {
		return nil, &requestError{fmt.Sprintf("takes must be 1..%d", maxTakesPerChunk)}
	}
	seed := randomSeed()
	if in.Seed != nil {
		if seed, err = voxSeed(map[string]any{fieldSeed: *in.Seed}); err != nil {
			return nil, err
		}
	}
	now := time.Now().UTC()
	id := vproject.NewID(now)
	out, err := p.outputPath(in, id)
	if err != nil {
		return nil, err
	}
	m := &vproject.Manifest{Version: vproject.Version, ID: id, Title: title(in, chunks), Created: now,
		Settings: vproject.Settings{Voice: voice, Style: style, Preset: name, CloneModePin: in.CloneMode, Seed: seed, Cfg: defaultCfgValue,
			Steps: defaultTimesteps, Takes: takes, LUFS: pr.lufs, ChunkPause: pr.opts.ChunkPause,
			ParagraphPause: pr.opts.ParagraphPause, OutPath: out, Overwrite: in.Overwrite, AllowBattery: in.AllowBattery},
		Notes: []string{vproject.NoteNumbers}}
	for _, c := range chunks {
		m.Chunks = append(m.Chunks, vproject.Chunk{Index: c.Index, Paragraph: c.Paragraph, Text: c.Text,
			Spoken: c.Spoken, Style: c.Style, PauseAfter: c.PauseAfter, Status: vproject.ChunkPending})
	}
	m.Progress.ChunksTotal = len(chunks)
	return m, p.diskPreflight(in.Script, takes)
}

// langOfText is langHint's answer for a script.
func langOfText(script string) string {
	return langHint(map[string]any{fieldInput: script})
}

// outputPath validates out_path (absolute .wav, five free siblings) or
// builds the default <output root>/<title or id>/<same>.wav (D18; the root is
// the QF5 default, config.DefaultProduceOutDir, injected through the ports).
func (p *producer) outputPath(in produceInput, id string) (string, error) {
	out := in.OutPath
	if out == "" {
		folder := id
		if in.Title != "" {
			if s := slugify(in.Title); s != "" {
				folder = s
			}
		}
		root := p.ports.OutputRoot()
		if !filepath.IsAbs(root) {
			// Config does not expand "~" in any path setting, so it is relative too.
			return "", &requestError{"the output folder setting (OX_SAY_PRODUCE_OUT_DIR) must be an absolute path such as /Users/you/Movies/ox-say; \"~\" and relative paths are not accepted. Fix it and restart ox-say, or pass out_path"}
		}
		out = filepath.Join(root, folder, folder+".wav")
		return out, checkOutputs(strings.TrimSuffix(out, ".wav"), in.Overwrite, nil)
	}
	if err := validateOutPath(out, []string{".wav"}, true); err != nil {
		return "", &requestError{err.Error()}
	}
	return out, checkOutputs(strings.TrimSuffix(out, ".wav"), in.Overwrite, nil)
}

func title(in produceInput, chunks []vscript.Chunk) string {
	t := strings.TrimSpace(in.Title)
	if t == "" {
		t = chunks[0].Text
	}
	r := []rune(t)
	return string(r[:min(len(r), titleRunes)])
}

// diskPreflight wants 2x the estimated takes + output on the home volume.
func (p *producer) diskPreflight(script string, takes int) error {
	audio := float64(utf8.RuneCountInString(script)) / estCharsPerSec
	need := uint64(diskFactor * audio * bytesPerAudioSec * (float64(takes)*takesMargin + outputCopies))
	var st unix.Statfs_t
	if err := unix.Statfs(p.ports.Home(), &st); err != nil {
		return nil // cannot tell: the ENOSPC path still reports a full disk in plain words
	}
	if free := uint64(st.Bavail) * uint64(st.Bsize); free < need {
		return &requestError{fmt.Sprintf("not enough free disk space: this voiceover needs about %.1f GB, %.1f GB are free", float64(need)/bytesPerGB, float64(free)/bytesPerGB)}
	}
	return nil
}

// makeProject creates <root>/<id> exclusively (0700) with takes/ and the script.
func (p *producer) makeProject(m *vproject.Manifest, script string) (string, error) {
	if err := os.MkdirAll(p.root, vproject.DirMode); err != nil {
		return "", err
	}
	dir := filepath.Join(p.root, m.ID)
	if err := os.Mkdir(dir, vproject.DirMode); err != nil {
		return "", err
	}
	// A directory without a manifest is invisible to list and cannot be
	// deleted through the API: any failure from here on removes it again.
	fail := func(err error) (string, error) {
		p.discard(dir)
		return "", err
	}
	if err := os.Mkdir(filepath.Join(dir, vproject.TakesDir), vproject.DirMode); err != nil {
		return fail(err)
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, vproject.ScriptFile), []byte(script), vproject.FileMode); err != nil {
		return fail(err)
	}
	// Until launch marks it running, a project that has not run is resumable:
	// "interrupted", not an empty status that nothing maps.
	m.Status = vproject.StatusInterrupted
	if err := m.Save(dir); err != nil {
		return fail(err)
	}
	return dir, nil
}

// refresh re-reads the voice and engine, recomputes effective styles, the
// effective clone mode (jobCloneMode under the job's pin, recorded into
// Settings.CloneMode) and each chunk's basis; a chunk whose basis changed is
// reset (D5, D10). It returns the base spec per chunk.
func (p *producer) refresh(j *job) ([]takeSpec, error) {
	p.mu.Lock()
	s := j.m.Settings
	chunks := append([]vproject.Chunk(nil), j.m.Chunks...)
	p.mu.Unlock()
	facts, err := p.ports.Voice(s.Voice)
	if err != nil {
		return nil, fmt.Errorf("voice %q: %w", s.Voice, err)
	}
	engineID, err := p.ports.EngineID()
	if err != nil {
		return nil, err
	}
	vc := make([]vscript.Chunk, len(chunks))
	for i, c := range chunks {
		vc[i] = vscript.Chunk{Style: c.Style, Spoken: c.Spoken}
	}
	mode, styles, err := jobCloneMode(facts, s.Style, vc, s.CloneModePin)
	if err != nil {
		return nil, err
	}
	specs := make([]takeSpec, len(chunks))
	for i, c := range chunks {
		specs[i] = takeSpec{V: takeKeyVersion, Engine: engineID, Voice: facts.Name, VoiceSHA: facts.SHA,
			RefText: facts.RefText, Mode: mode, Style: styles[i], Text: c.Spoken, Seed: s.Seed, Cfg: s.Cfg, Steps: s.Steps}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	j.m.Settings.CloneMode, j.m.Settings.VoiceSHA, j.m.Settings.Engine = mode, facts.SHA, engineID
	for i := range j.m.Chunks {
		c := &j.m.Chunks[i]
		if b := specs[i].basis(); c.Basis != b {
			c.Basis, c.Takes, c.Pick, c.UserPick, c.Reasons, c.Status = b, nil, "", false, nil, vproject.ChunkPending
		}
	}
	j.m.Progress.ChunksDone = countSettled(j.m.Chunks)
	return specs, j.m.Save(j.dir)
}

// loadProject reads a project's manifest after validating its id and
// containment. It touches nothing on disk (no sweep) and refuses a manifest
// that names another project.
func (p *producer) loadProject(id string) (*job, error) {
	if !vproject.ValidID(id) {
		return nil, errNoProject
	}
	dir := filepath.Join(p.root, id)
	if err := vproject.Contained(p.root, dir); err != nil {
		p.log.Debug("produce: not a project directory", slog.String("id", id), slog.Any("error", err))
		return nil, errNoProject
	}
	m, err := vproject.Load(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, errNoProject
	}
	if err != nil {
		return nil, err
	}
	if m.ID != id {
		return nil, fmt.Errorf("project %s: the manifest belongs to another project", id)
	}
	j := &job{dir: dir, m: m, regen: map[int]int{}}
	j.allowBattery.Store(m.Settings.AllowBattery)
	return j, nil
}

// open loads a project that is not running (busy otherwise). The temp sweep
// happens in launch, behind the same busy check, under the lock.
func (p *producer) open(id string) (*job, error) {
	if !vproject.ValidID(id) {
		return nil, errNoProject
	}
	p.mu.Lock()
	busy := p.cur
	p.mu.Unlock()
	if busy != nil {
		return nil, &busyError{busy.m.ID}
	}
	return p.loadProject(id)
}

// resume runs a project again: missing or stale chunks render, the rest
// come from the cache. allowBattery also releases a paused running job.
func (p *producer) resume(id string, allowBattery bool) (vproject.Summary, error) {
	if err := p.ready(); err != nil {
		return vproject.Summary{}, err
	}
	p.mu.Lock()
	if cur := p.cur; cur != nil && cur.m.ID == id {
		// A cancel is pending: answering "running" would be a lie, since the
		// job ends cancelled. Clearing the flag instead would undo what the
		// user asked for, and race with a checkpoint that already acted on it.
		if cur.cancel.Load() {
			p.mu.Unlock()
			return vproject.Summary{}, &cancellingError{id}
		}
		if allowBattery {
			cur.allowBattery.Store(true)
		}
		s := cur.m.Summary()
		p.mu.Unlock()
		return s, nil
	}
	p.mu.Unlock()
	j, err := p.open(id)
	if err != nil {
		return vproject.Summary{}, err
	}
	if allowBattery {
		j.allowBattery.Store(true)
		j.m.Settings.AllowBattery = true
	}
	return p.launch(j)
}

// chunk applies an op to a project that is not running and launches it.
func (p *producer) chunk(id string, index int, op chunkOp) (vproject.Summary, error) {
	if err := p.ready(); err != nil {
		return vproject.Summary{}, err
	}
	j, err := p.open(id)
	if err != nil {
		return vproject.Summary{}, err
	}
	if index < 0 || index >= len(j.m.Chunks) {
		return vproject.Summary{}, &requestError{fmt.Sprintf("chunk %d: the project has %d chunks", index, len(j.m.Chunks))}
	}
	c := &j.m.Chunks[index]
	switch op.Action {
	case opPick:
		if !listed(c.Takes, op.Take) {
			return vproject.Summary{}, &requestError{"take is not one of this chunk's takes"}
		}
		c.Pick, c.UserPick = op.Take, true
		settle(c)
	case opRegenerate:
		if op.Takes < 1 || op.Takes > maxTakesPerChunk {
			return vproject.Summary{}, &requestError{fmt.Sprintf("takes must be 1..%d", maxTakesPerChunk)}
		}
		j.regen[index] = op.Takes
	case opEdit:
		if err := editChunk(c, op.Text, j.m.Settings.Preset, projectLanguage(j.m)); err != nil {
			return vproject.Summary{}, err
		}
	case opDelivery:
		return p.deliver(j, []deliveryEntry{{N: &index, Style: op.Style, PauseAfter: op.PauseAfter, Pace: op.Pace}})
	default:
		return vproject.Summary{}, &requestError{fmt.Sprintf("action %q: want pick, regenerate, edit or delivery", op.Action)}
	}
	return p.launch(j)
}

// delivery applies a batch of style/pause changes to a project that is not
// running and launches it once.
func (p *producer) delivery(id string, es []deliveryEntry) (vproject.Summary, error) {
	if err := p.ready(); err != nil {
		return vproject.Summary{}, err
	}
	j, err := p.open(id)
	if err != nil {
		return vproject.Summary{}, err
	}
	return p.deliver(j, es)
}

// deliver validates every entry before changing anything, refuses a batch
// that would move the job's clone mode, then applies and launches. A
// pause- or pace-only batch re-assembles without a render or a checkpoint;
// a real pace is refused here when this machine cannot stretch.
func (p *producer) deliver(j *job, es []deliveryEntry) (vproject.Summary, error) {
	styles, err := validateDelivery(j.m, es)
	if err != nil {
		return vproject.Summary{}, err
	}
	// The mode gate comes first: a batch that is a conflict on any host must
	// not read as "no ffmpeg" on one without it.
	eff, effAfter, err := p.deliveryModeGate(j, es, styles)
	if err != nil {
		return vproject.Summary{}, err
	}
	if needPace(es) {
		if err := paceOK(); err != nil {
			return vproject.Summary{}, &unavailableError{err.Error()}
		}
	}
	p.mu.Lock()
	assembleOnly := true
	for i, e := range es {
		c := &j.m.Chunks[*e.N]
		// The stored style and the effective one are different questions: the
		// request is stored whenever the chunk's own field changes (a pin equal
		// to the style it inherits still survives a later voice update), and
		// takes are superseded and re-rendered only when the style the engine
		// is asked for changes. eff and effAfter are nil only for batches with
		// no style entry.
		if e.Style != nil {
			c.Style = styles[i]
			if effAfter[*e.N] != eff[*e.N] {
				c.Superseded = supersedeTakes(c.Superseded, c.Takes)
				assembleOnly = false
			}
		}
		if e.PauseAfter != nil {
			c.PauseAfter = *e.PauseAfter
		}
		if e.Pace != nil {
			c.Pace = *e.Pace
		}
	}
	j.assembleOnly = assembleOnly
	p.mu.Unlock()
	return p.launch(j)
}

// validateDelivery checks the whole batch and returns each entry's cleaned
// style ("" where the entry has none); nothing is applied when it errs.
func validateDelivery(m *vproject.Manifest, es []deliveryEntry) ([]string, error) {
	if len(es) == 0 {
		return nil, &requestError{"chunks must name at least one chunk"}
	}
	styles := make([]string, len(es))
	seen := map[int]bool{}
	for i, e := range es {
		if e.N == nil {
			return nil, &requestError{fmt.Sprintf("entry %d: n is required", i)}
		}
		if n := *e.N; n < 0 || n >= len(m.Chunks) {
			return nil, &requestError{fmt.Sprintf("chunk %d: the project has %d chunks", n, len(m.Chunks))}
		} else if seen[n] {
			return nil, &requestError{fmt.Sprintf("chunk %d is named twice", n)}
		} else {
			seen[n] = true
		}
		if e.Style == nil && e.PauseAfter == nil && e.Pace == nil {
			return nil, &requestError{fmt.Sprintf("chunk %d: delivery needs style, pause_after or pace", *e.N)}
		}
		if e.Style != nil {
			styles[i] = vscript.CleanStyle(*e.Style)
			if utf8.RuneCountInString(styles[i]) > vscript.MaxStyleChars {
				return nil, &requestError{fmt.Sprintf("style is longer than %d characters", vscript.MaxStyleChars)}
			}
		}
		if e.PauseAfter != nil && !deliveryPauseOK(*e.PauseAfter) {
			return nil, &requestError{fmt.Sprintf("a pause must be 0 (clears it) or %.2f–%.0f s", vscript.MinPause, vscript.MaxPause)}
		}
		if e.Pace != nil && !deliveryPaceOK(*e.Pace) {
			return nil, &requestError{fmt.Sprintf("chunk %d: a pace of %v; want 0 or %.2f–%.2f", *e.N, *e.Pace, vproject.PaceMin, vproject.PaceMax)}
		}
	}
	return styles, nil
}

// deliveryPauseOK: a stored pause of 0 means "no pause"; a real pause stays
// inside the [pause Ns] directive's range. NaN and ±Inf are refused outright
// even though no transport can carry them today.
func deliveryPauseOK(p float64) bool {
	return !math.IsNaN(p) && !math.IsInf(p, 0) && (p == 0 || (p >= vscript.MinPause && p <= vscript.MaxPause))
}

// deliveryPaceOK: a stored pace of 0 is neutral; a real one stays inside the
// atempo band the manifest itself validates. NaN and ±Inf are refused
// outright even though no transport can carry them today.
func deliveryPaceOK(r float64) bool {
	return !math.IsNaN(r) && !math.IsInf(r, 0) && (r == 0 || (r >= vproject.PaceMin && r <= vproject.PaceMax))
}

// needPace reports whether the batch sets a real pace anywhere; clearing
// one (0) or setting the neutral 1.0 needs no atempo, and neither does
// anything else (tl.add does not stretch at 1.0).
func needPace(es []deliveryEntry) bool {
	for _, e := range es {
		if e.Pace != nil && *e.Pace != 0 && *e.Pace != 1 {
			return true
		}
	}
	return false
}

// deliveryModeGate refuses a batch whose style changes would move the job's
// effective clone mode (an ultimate job turning reference re-renders every
// chunk, which is a recreate, not a delivery change). A job pinned to
// reference at create cannot leave it; one pinned to ultimate refuses any
// style op. It returns each chunk's effective style under the current state,
// so a style op can tell a real change from a no-op, and each chunk's effective
// style once the batch is applied — both nil when no style op can apply.
func (p *producer) deliveryModeGate(j *job, es []deliveryEntry, styles []string) (before, after []string, err error) {
	pin := j.m.Settings.CloneModePin
	styled := false
	for _, e := range es {
		if e.Style != nil {
			styled = true
			break
		}
	}
	switch pin {
	case cloneUltimate:
		if styled {
			return nil, nil, &conflictError{deliveryIsUltimate}
		}
		return nil, nil, nil
	case cloneReference:
		if !styled {
			return nil, nil, nil
		}
	}
	facts, err := p.ports.Voice(j.m.Settings.Voice)
	if err != nil {
		return nil, nil, fmt.Errorf("voice %q: %w", j.m.Settings.Voice, err)
	}
	vc := make([]vscript.Chunk, len(j.m.Chunks))
	for i, c := range j.m.Chunks {
		vc[i] = vscript.Chunk{Style: c.Style, Spoken: c.Spoken}
	}
	modeBefore, before, err := jobCloneMode(facts, j.m.Settings.Style, vc, pin)
	if err != nil {
		return nil, nil, err
	}
	for i, e := range es {
		if e.Style != nil {
			vc[*e.N].Style = styles[i]
		}
	}
	modeAfter, after, err := jobCloneMode(facts, j.m.Settings.Style, vc, pin)
	if err != nil {
		return nil, nil, err
	}
	// Pinned to reference already: no style op moves the mode.
	if pin != cloneReference && modeAfter != modeBefore {
		return nil, nil, &conflictError{deliveryNeedsReference}
	}
	return before, after, nil
}

// supersedeTakes moves the keys of ts onto cur, deduplicated, keeping at
// most the last maxSupersededTakes.
func supersedeTakes(cur []string, ts []vproject.TakeRef) []string {
	have := map[string]bool{}
	for _, k := range cur {
		have[k] = true
	}
	for _, t := range ts {
		if !have[t.Key] {
			cur, have[t.Key] = append(cur, t.Key), true
		}
	}
	if n := len(cur) - maxSupersededTakes; n > 0 {
		cur = cur[n:]
	}
	return cur
}

// projectLanguage is the language of a project's script, decided from the text
// of all its chunks as Parse decided it from the script ("" for no letters).
// An edit is spoken in the project's language, whatever its own words are.
func projectLanguage(m *vproject.Manifest) string {
	var b strings.Builder
	for _, c := range m.Chunks {
		b.WriteString(c.Text)
		b.WriteByte(' ')
	}
	return vscript.SpokenLanguage(b.String())
}

// editChunk replaces one chunk's text: one piece of text, no directives,
// within the preset's MaxChars.
func editChunk(c *vproject.Chunk, text, preset, lang string) error {
	pr := presets[preset]
	pr.opts.Language = lang
	parsed, err := vscript.Parse(text, pr.opts)
	if err != nil {
		return &requestError{err.Error()}
	}
	if len(parsed) != 1 || parsed[0].PauseAfter != 0 || strings.Contains(text, "[") || utf8.RuneCountInString(text) > pr.opts.MaxChars {
		return &requestError{fmt.Sprintf("an edit is one piece of text of at most %d characters, without [directives]", pr.opts.MaxChars)}
	}
	c.Text, c.Spoken = parsed[0].Text, parsed[0].Spoken
	c.Takes, c.Pick, c.UserPick, c.Reasons, c.Basis, c.Status = nil, "", false, nil, "", vproject.ChunkPending
	return nil
}

func listed(ts []vproject.TakeRef, key string) bool {
	for _, t := range ts {
		if t.Key == key {
			return true
		}
	}
	return false
}

// cancel flags the running job; a project that exists but is not running is
// answered errNotRunning, never a pretended cancel.
func (p *producer) cancel(id string) error {
	if !vproject.ValidID(id) {
		return errNoProject
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cur != nil && p.cur.m.ID == id {
		p.cur.cancel.Store(true)
		p.cur.stopWait() // ends a dictation or battery wait now, not at the next poll
		return nil
	}
	if _, err := os.Stat(filepath.Join(p.root, id, vproject.ManifestFile)); err != nil {
		return errNoProject
	}
	return errNotRunning
}

// status is the summary of a project; a stale active status on disk reads
// as interrupted.
func (p *producer) status(id string) (vproject.Summary, error) {
	m, err := p.manifest(id)
	if err != nil {
		return vproject.Summary{}, err
	}
	return m.Summary(), nil
}

// manifest is a private copy of a project's manifest.
func (p *producer) manifest(id string) (*vproject.Manifest, error) {
	if !vproject.ValidID(id) {
		return nil, errNoProject
	}
	p.mu.Lock()
	if p.cur != nil && p.cur.m.ID == id {
		m := p.cur.m.Clone()
		p.mu.Unlock()
		return m, nil
	}
	p.mu.Unlock()
	j, err := p.loadProject(id)
	if err != nil {
		return nil, err
	}
	switch j.m.Status {
	case vproject.StatusRunning, vproject.StatusWaitingForDictation, vproject.StatusPausedOnBattery:
		j.m.Status = vproject.StatusInterrupted
	}
	return j.m, nil
}

// chunkDetailOut is the full view of one chunk: its takes with file paths
// and heard words, for listening and inspection.
type chunkDetailOut struct {
	vproject.Chunk
	TakeFiles map[string]string `json:"take_files"` // key -> absolute WAV path
}

func (p *producer) chunkDetail(id string, index int) (chunkDetailOut, error) {
	m, err := p.manifest(id)
	if err != nil {
		return chunkDetailOut{}, err
	}
	if index < 0 || index >= len(m.Chunks) {
		return chunkDetailOut{}, &requestError{fmt.Sprintf("chunk %d: the project has %d chunks (numbered from 0)", index, len(m.Chunks))}
	}
	out := chunkDetailOut{Chunk: m.Chunks[index], TakeFiles: map[string]string{}}
	for _, t := range out.Takes {
		out.TakeFiles[t.Key] = filepath.Join(p.root, id, vproject.TakesDir, t.Key+".wav")
	}
	return out, nil
}

// list summarises the most recent maxListedProjects projects, newest first,
// without their chunk lists.
func (p *producer) list() ([]vproject.Summary, error) {
	entries, err := os.ReadDir(p.root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []vproject.Summary
	for k := len(entries) - 1; k >= 0 && len(out) < maxListedProjects; k-- {
		if id := entries[k].Name(); vproject.ValidID(id) {
			if s, err := p.status(id); err == nil {
				s.Chunks = []vproject.ChunkSummary{} // the list is an overview: ask for one project to see its chunks
				out = append(out, s)
			}
		}
	}
	return out, nil
}

// removeAll is os.RemoveAll; a var so a test can hold a delete open.
var removeAll = os.RemoveAll

// remove deletes a project that is not running; its published outputs
// stay unless deleteOutputs. The project is marked as being removed under the
// lock, which makes launch answer busy, and the load and the delete run
// outside it: a large delete must not block status, cancel or shutdown.
func (p *producer) remove(id string, deleteOutputs bool) error {
	if !vproject.ValidID(id) {
		return errNoProject
	}
	p.mu.Lock()
	if p.cur != nil {
		busy := p.cur.m.ID
		p.mu.Unlock()
		return &busyError{busy}
	}
	if p.removing != "" {
		busy := p.removing
		p.mu.Unlock()
		return &busyError{busy}
	}
	p.removing = id
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		p.removing = ""
		p.mu.Unlock()
	}()
	j, err := p.loadProject(id)
	if err != nil {
		return err
	}
	if deleteOutputs {
		if err := p.deleteOwnedOutputs(j.m); err != nil {
			return err
		}
	}
	return removeAll(j.dir)
}

// ownedPaths is the one proof that the files at a project's output stem are
// its own, used by DELETE-with-outputs and by re-assembly alike (#154.6): the
// stem must come from a valid out_path, every recorded output must be exactly
// stem+ext, none of the existing files may be a symlink or a non-regular
// file, the exported manifest beside them must name this very project, and the
// WAV must still be the one this project published (its recorded sha256). A
// hand-edited manifest, a project whose files were moved away and replaced by
// another's, and a file the user saved over the WAV are therefore all "not
// ours". It returns nil when nothing was published.
func ownedPaths(m *vproject.Manifest) ([]string, error) {
	o := m.Outputs
	if o.WAV == "" && o.SRT == "" && o.VTT == "" && o.Words == "" && o.Manifest == "" {
		return nil, nil
	}
	stem, err := outputStem(m.Settings.OutPath)
	if err != nil {
		return nil, &requestError{"the project's output location is not valid; delete its files by hand"}
	}
	recorded := map[string]string{".wav": o.WAV, ".srt": o.SRT, ".vtt": o.VTT, ".words.json": o.Words, ".manifest.json": o.Manifest}
	var paths []string
	for _, ext := range outputExts {
		if got := recorded[ext]; got != "" && got != stem+ext {
			return nil, &requestError{"the project's recorded output files do not match its output location; delete them by hand"}
		}
		paths = append(paths, stem+ext)
	}
	errNotOurs := &requestError{"the output files beside this project are not marked as its own; delete them by hand"}
	for _, path := range paths {
		if st, err := os.Lstat(path); err == nil && !st.Mode().IsRegular() {
			return nil, errNotOurs
		}
	}
	raw, err := os.ReadFile(stem + ".manifest.json")
	var export struct {
		ID string `json:"id"`
	}
	if err != nil || json.Unmarshal(raw, &export) != nil || export.ID != m.ID {
		return nil, errNotOurs
	}
	if want := o.WAVSHA256; want != "" {
		// A WAV that is gone (deleted by hand) leaves nothing of ours to
		// protect: the siblings are vouched for by the export, and must not
		// block the next assembly (#156.11).
		if got, err := fileSHA(stem + ".wav"); err != nil && !errors.Is(err, os.ErrNotExist) || err == nil && got != want {
			return nil, errNotOurs
		}
	}
	return paths, nil
}

// deleteOwnedOutputs removes the regular files ownedPaths vouches for.
func (p *producer) deleteOwnedOutputs(m *vproject.Manifest) error {
	paths, err := ownedPaths(m)
	if err != nil {
		return err
	}
	for _, path := range paths {
		if st, err := os.Lstat(path); err == nil && st.Mode().IsRegular() {
			if err := os.Remove(path); err != nil {
				p.log.Warn("produce: cannot remove an output", slog.String("file", filepath.Base(path)), slog.Any("error", err))
			}
		}
	}
	return nil
}

// fileSHA is the sha256 of a file, hex.
func fileSHA(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
