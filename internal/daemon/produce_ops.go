package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
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
	titleRunes   = 60
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
	Action string
	Takes  int
	Take   string
	Text   string
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
		return nil, &requestError{fmt.Sprintf("the script must have 1–%d characters (about an hour of speech); it has %d", maxProduceChars, n)}
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
	if _, err := p.ports.Voice(voice); err != nil {
		return nil, err
	}
	style := vscript.CleanStyle(in.Style)
	if utf8.RuneCountInString(style) > vscript.MaxStyleChars {
		return nil, &requestError{fmt.Sprintf("style is longer than %d characters", vscript.MaxStyleChars)}
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
		Settings: vproject.Settings{Voice: voice, Style: style, Preset: name, Seed: seed, Cfg: defaultCfgValue,
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
	if err := os.Mkdir(filepath.Join(dir, vproject.TakesDir), vproject.DirMode); err != nil {
		return "", err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, vproject.ScriptFile), []byte(script), vproject.FileMode); err != nil {
		return "", err
	}
	return dir, m.Save(dir)
}

// refresh re-reads the voice and engine, recomputes effective styles, the
// clone mode (the adapter's own rule, jobCloneMode) and each chunk's basis; a
// chunk whose basis changed is reset (D5, D10). It returns the base spec per
// chunk.
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
	mode, styles, err := jobCloneMode(facts, s.Style, vc)
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
			c.Basis, c.Takes, c.Pick, c.Reasons, c.Status = b, nil, "", nil, vproject.ChunkPending
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
		if err := editChunk(c, op.Text, j.m.Settings.Preset); err != nil {
			return vproject.Summary{}, err
		}
	default:
		return vproject.Summary{}, &requestError{fmt.Sprintf("action %q: want pick, regenerate or edit", op.Action)}
	}
	return p.launch(j)
}

// editChunk replaces one chunk's text: one piece of text, no directives,
// within the preset's MaxChars.
func editChunk(c *vproject.Chunk, text, preset string) error {
	pr := presets[preset]
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

// cancel flags the running job; a project that is not running is a no-op.
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
	return nil
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
		return chunkDetailOut{}, errNoProject
	}
	out := chunkDetailOut{Chunk: m.Chunks[index], TakeFiles: map[string]string{}}
	for _, t := range out.Takes {
		out.TakeFiles[t.Key] = filepath.Join(p.root, id, vproject.TakesDir, t.Key+".wav")
	}
	return out, nil
}

// list summarises every project, newest first.
func (p *producer) list() ([]vproject.Summary, error) {
	entries, err := os.ReadDir(p.root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []vproject.Summary
	for k := len(entries) - 1; k >= 0; k-- {
		if id := entries[k].Name(); vproject.ValidID(id) {
			if s, err := p.status(id); err == nil {
				out = append(out, s)
			}
		}
	}
	return out, nil
}

// remove deletes a project that is not running; its published outputs
// stay unless deleteOutputs. The whole operation holds the producer lock, so
// no launch can start on the project being removed.
func (p *producer) remove(id string, deleteOutputs bool) error {
	if !vproject.ValidID(id) {
		return errNoProject
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cur != nil {
		return &busyError{p.cur.m.ID}
	}
	j, err := p.loadProject(id)
	if err != nil {
		return err
	}
	if deleteOutputs {
		if err := p.deleteOwnedOutputs(j.m); err != nil {
			return err
		}
	}
	return os.RemoveAll(j.dir)
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
		if got, err := fileSHA(stem + ".wav"); err != nil || got != want {
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
