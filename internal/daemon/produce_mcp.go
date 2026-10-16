package daemon

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// The produce tools return at once: create/resume/edit start a background job
// and answer with its summary, status and control are reads. That is why none
// of them has a ToolTimeouts entry (guard.go ServerConfig): a tool that waited
// for the voiceover would need a timeout of the voiceover's length, and an
// agent would sit blocked for minutes.

// presetNames lists the presets for the tool texts, from the registry itself.
func presetNames() string {
	names := make([]string, 0, len(presets))
	for n := range presets {
		names = append(names, n)
	}
	sort.Strings(names)
	return `"` + strings.Join(names, `", "`) + `"`
}

func produceDescription() string {
	return fmt.Sprintf(`Turn a script into one long voiceover with VoxCPM2 (Apple Silicon). Returns AT ONCE with a project `+"`id`"+` and status "running"; poll produce_status every ~10 s. %s One voiceover at a time: if another is running you get its id back. Needs a saved voice (voice, else the configured default).

Script: plain text; blank lines separate paragraphs. [pause 0.8s] (or [pause 300ms]; [pause] = 0.6 s) inserts exact silence anywhere. [style: excited and joyful, lively pace] at the very start of a paragraph sets that paragraph's delivery (short English descriptors). Any other [...] is an error. style is the default delivery for every paragraph. Up to %d characters.

preset: "youtube" (default: loudness target -16 LUFS, calm pauses, 1 take per chunk), "reels" (target -14 LUFS, tighter pauses, 2 takes per chunk to choose from), "voice-under-music" (target -18 LUFS); all presets: %s. Loudness values are targets: the measured level can sit a little lower when the true-peak limit holds the gain back. seed makes it reproducible (the status reports the seed used). takes (1-%d) overrides takes per chunk. There are no cfg_value, steps or loudness options: presets carry them.
Output: a 48 kHz WAV plus .srt, .vtt, .words.json (word timings for animated captions) and .manifest.json next to it, in out_path (absolute .wav; existing files refused unless overwrite) or the daemon's output folder (OX_SAY_PRODUCE_OUT_DIR, default ~/Movies/ox-say/): a folder and files named from title (lowercased, letters and digits, up to 32 characters) or, with no title, the project id. On battery the job pauses unless allow_battery.`, produceTimeText, maxProduceChars, presetNames(), maxTakesPerChunk)
}

// produceTimeText is the time budget an agent plans around; the README states
// the same numbers (measured, F1-6 live acceptance).
const produceTimeText = `A 60 s reel takes about 1.5-2 minutes (reels: 2 takes per chunk), 10 minutes of speech about 11-12 minutes with 1 take per chunk (youtube); the first call after idle adds 10-40 s to load the model.`

var produceStatusDescription = fmt.Sprintf(`Progress of a project: status (running, waiting_for_dictation, paused_on_battery, review, done, failed, cancelled, interrupted), chunks done/total, ETA, outputs, and per chunk its status, pick and reasons. Without id: the %d most recent projects (newest first) under "projects", without their chunk lists. With id: the project under "project". With id and chunk (0-based): that chunk's detail under "chunk" - its takes with file paths (take_files), durations and word errors. `+
	`"review" means the file is ready but some chunks failed the automatic checks after 3 attempts: get that chunk's detail, listen to its takes, then use produce_edit. `+
	`The checks reject broken audio (long silences, wrong or missing words); they do not judge expressiveness. Numbers are spoken as words and checked; only numbers left as digits are not (the note says: %q). When the list is capped, "note" says so.`, maxListedProjects, vproject.NoteNumbers)

const produceEditDescription = `Change one chunk (0-based index, see produce_status) of a project that is not running: action "regenerate" renders takes (1-3) more takes with new seeds; "pick" chooses one of the chunk's takes by take (its key from produce_status with chunk); "edit" replaces the chunk's text (one piece of text, no [directives]) and renders only that chunk; "delivery" changes its style, pause_after and/or pace ("" clears the style to the project default; pace is a 0.85-1.15 rate, 0 restores neutral, and needs ffmpeg's atempo filter on this machine; only chunks whose style changed render, a pause or pace alone just re-assembles). With chunks [{n, style?, pause_after?, pace?}...] delivery applies every entry under one launch; chunk is then not needed. On a clone voice in auto mode a style is refused: create with clone_mode reference. The file is re-assembled; poll produce_status. ` +
	`Regenerate does NOT change the chunk's pick: your pick is kept until you choose another. A pick is your decision after listening: the chunk becomes ok even if that take failed the automatic checks (the chunk then shows user_pick true), so the project can reach done; a silent take cannot be accepted. The new takes are the keys that were not there before: read produce_status {id, chunk}, listen to take_files, then call produce_edit {action: "pick", take: <key>}. A pick re-assembles the file in seconds.`

const produceControlDescription = `action "resume" continues an interrupted, cancelled or finished project (only missing or changed chunks render; allow_battery lets it run on battery), "cancel" stops a running one (the take being rendered finishes and is kept), "remove" deletes the project's working files; the published voiceover files (.wav .srt .vtt .words.json .manifest.json) stay unless delete_outputs is true, which deletes the finished voiceover files for good (only files this project published, and only if they are unchanged). A project that is not running cannot be cancelled: cancel then answers an error saying so.`

type produceIn struct {
	Script       string `json:"script" jsonschema:"The voiceover text. Blank line = new paragraph; [pause 0.8s] exact silence; [style: ...] opens a paragraph. Up to 40000 characters"`
	Title        string `json:"title,omitempty" jsonschema:"Names the output folder and files: the title lowercased, letters and digits only, at most 32 characters; without a title the project id is used"`
	Voice        string `json:"voice,omitempty" jsonschema:"Saved voice name (a recording of at most 30 s, see voices_list); omit for the configured default voice"`
	Style        string `json:"style,omitempty" jsonschema:"Default delivery for every paragraph: short English descriptors, up to 300 characters, e.g. calm and warm, slow"`
	Preset       string `json:"preset,omitempty" jsonschema:"youtube (default) | reels | voice-under-music: loudness, pauses and takes per chunk"`
	Seed         *int64 `json:"seed,omitempty" jsonschema:"0-4294967295; reproduces the whole voiceover; the status reports the seed used"`
	Takes        *int   `json:"takes,omitempty" jsonschema:"Takes per chunk, 1-3; overrides the preset; 0 is refused"`
	CloneMode    string `json:"clone_mode,omitempty" jsonschema:"auto (default; the adapter's rule per job) | reference (every chunk clones the timbre only; styles may steer) | ultimate (the job continues the voice's recording; needs ref_text, and any style — job, [style:] or the voice's own — is refused)"`
	OutPath      string `json:"out_path,omitempty" jsonschema:"Absolute path of the final .wav; its .srt .vtt .words.json .manifest.json go beside it; existing files refused unless overwrite"`
	Overwrite    bool   `json:"overwrite,omitempty" jsonschema:"Allow replacing existing files at out_path"`
	AllowBattery bool   `json:"allow_battery,omitempty" jsonschema:"Keep going on battery power (default: the job pauses until the Mac is plugged in)"`
}

type produceStatusIn struct {
	ID    string `json:"id,omitempty" jsonschema:"Project id from produce; omit to list all projects"`
	Chunk *int   `json:"chunk,omitempty" jsonschema:"Chunk index (0-based) for that chunk's detail: takes, file paths, word errors; needs id"`
}

type produceEditIn struct {
	ID         string          `json:"id" jsonschema:"Project id"`
	Chunk      *int            `json:"chunk,omitempty" jsonschema:"Chunk index, 0-based (see produce_status chunks); needed by every action but a delivery batch"`
	Action     string          `json:"action" jsonschema:"regenerate | pick | edit | delivery"`
	Takes      int             `json:"takes,omitempty" jsonschema:"regenerate: how many more takes to render, 1-3"`
	Take       string          `json:"take,omitempty" jsonschema:"pick: the take key from produce_status with chunk (24 hex characters)"`
	Text       string          `json:"text,omitempty" jsonschema:"edit: the chunk's new text; one piece, no [directives]"`
	Style      *string         `json:"style,omitempty" jsonschema:"delivery: the chunk's new delivery, e.g. excited, lively; \"\" clears it to the project default"`
	PauseAfter *float64        `json:"pause_after,omitempty" jsonschema:"delivery: silence after the chunk in seconds; 0 clears it"`
	Pace       *float64        `json:"pace,omitempty" jsonschema:"delivery: the chunk's speech rate multiplier, 0.85-1.15 (0.9 slower, 1.1 faster); 0 restores neutral; needs ffmpeg's atempo filter on this machine"`
	Chunks     []deliveryEntry `json:"chunks,omitempty" jsonschema:"delivery batch: apply every entry under one launch; chunk is not needed"`
}

type produceControlIn struct {
	ID            string `json:"id" jsonschema:"Project id"`
	Action        string `json:"action" jsonschema:"resume | cancel | remove"`
	AllowBattery  bool   `json:"allow_battery,omitempty" jsonschema:"resume: keep going on battery power"`
	DeleteOutputs bool   `json:"delete_outputs,omitempty" jsonschema:"remove: ALSO delete the finished voiceover files (.wav .srt .vtt .words.json .manifest.json) for good; default false keeps them"`
}

type produceStatusOut struct {
	Note     string             `json:"note,omitempty"`
	Project  *vproject.Summary  `json:"project,omitempty"`
	Projects []vproject.Summary `json:"projects,omitempty"`
	Chunk    *chunkDetailOut    `json:"chunk,omitempty"`
}

type produceEditOut struct {
	Project vproject.Summary `json:"project"`
	Next    string           `json:"next"`
}

type produceControlOut struct {
	Status  string            `json:"status"`
	Project *vproject.Summary `json:"project,omitempty"`
}

const (
	controlResume = "resume"
	controlCancel = "cancel"
	controlRemove = "remove"
)

const editNext = "Poll produce_status until the project leaves running. After regenerate the chunk's pick is unchanged: read produce_status {id, chunk} for the new takes (keys not seen before), listen, then produce_edit {action: \"pick\", take: <key>}."

func (d *Daemon) registerProduceTools(srv *mcp.Server) {
	mcp.AddTool(srv, &mcp.Tool{Name: "produce", Description: produceDescription()}, d.toolProduce)
	mcp.AddTool(srv, &mcp.Tool{Name: "produce_status", Description: produceStatusDescription}, d.toolProduceStatus)
	mcp.AddTool(srv, &mcp.Tool{Name: "produce_edit", Description: produceEditDescription}, d.toolProduceEdit)
	mcp.AddTool(srv, &mcp.Tool{Name: "produce_control", Description: produceControlDescription}, d.toolProduceControl)
}

// produceErr is err in the plain words the HTTP surface uses: no internal path.
func (d *Daemon) produceErr(err error) error {
	d.log.Debug("produce tool failed", "error", err)
	return errors.New(d.prod.public(err))
}

func (d *Daemon) toolProduce(_ context.Context, _ *mcp.CallToolRequest, in produceIn) (*mcp.CallToolResult, vproject.Summary, error) {
	takes, err := explicitTakes(in.Takes)
	if err != nil {
		return nil, vproject.Summary{}, d.produceErr(err)
	}
	s, err := d.prod.create(produceInput{Script: in.Script, Title: in.Title, Voice: in.Voice, Style: in.Style,
		Preset: in.Preset, OutPath: in.OutPath, Seed: in.Seed, Takes: takes, Overwrite: in.Overwrite, AllowBattery: in.AllowBattery,
		CloneMode: in.CloneMode})
	if err != nil {
		return nil, vproject.Summary{}, d.produceErr(err)
	}
	return nil, s, nil
}

func (d *Daemon) toolProduceStatus(_ context.Context, _ *mcp.CallToolRequest, in produceStatusIn) (*mcp.CallToolResult, produceStatusOut, error) {
	switch {
	case in.ID == "" && in.Chunk != nil:
		return nil, produceStatusOut{}, errors.New("chunk needs id")
	case in.ID == "":
		list, err := d.prod.list()
		if err != nil {
			return nil, produceStatusOut{}, d.produceErr(err)
		}
		out := produceStatusOut{Projects: list}
		if len(list) >= maxListedProjects {
			out.Note = fmt.Sprintf("showing the %d most recent projects", maxListedProjects)
		}
		return nil, out, nil
	case in.Chunk != nil:
		c, err := d.prod.chunkDetail(in.ID, *in.Chunk)
		if err != nil {
			return nil, produceStatusOut{}, d.produceErr(err)
		}
		return nil, produceStatusOut{Chunk: &c}, nil
	}
	s, err := d.prod.status(in.ID)
	if err != nil {
		return nil, produceStatusOut{}, d.produceErr(err)
	}
	return nil, produceStatusOut{Project: &s}, nil
}

func (d *Daemon) toolProduceEdit(_ context.Context, _ *mcp.CallToolRequest, in produceEditIn) (*mcp.CallToolResult, produceEditOut, error) {
	var s vproject.Summary
	var err error
	switch {
	case in.Chunks != nil:
		if in.Action != opDelivery {
			err = &requestError{"chunks applies to action delivery only"}
			break
		}
		s, err = d.prod.delivery(in.ID, in.Chunks)
	case in.Chunk == nil:
		err = &requestError{fmt.Sprintf("action %q needs chunk", in.Action)}
	default:
		s, err = d.prod.chunk(in.ID, *in.Chunk, chunkOp{Action: in.Action, Takes: in.Takes, Take: in.Take,
			Text: in.Text, Style: in.Style, PauseAfter: in.PauseAfter, Pace: in.Pace})
	}
	if err != nil {
		return nil, produceEditOut{}, d.produceErr(err)
	}
	return nil, produceEditOut{Project: s, Next: editNext}, nil
}

func (d *Daemon) toolProduceControl(_ context.Context, _ *mcp.CallToolRequest, in produceControlIn) (*mcp.CallToolResult, produceControlOut, error) {
	switch in.Action {
	case controlResume:
		s, err := d.prod.resume(in.ID, in.AllowBattery)
		if err != nil {
			return nil, produceControlOut{}, d.produceErr(err)
		}
		return nil, produceControlOut{Status: s.Status, Project: &s}, nil
	case controlCancel:
		if err := d.prod.cancel(in.ID); err != nil {
			return nil, produceControlOut{}, d.produceErr(err)
		}
		return nil, produceControlOut{Status: "cancelling"}, nil
	case controlRemove:
		if err := d.prod.remove(in.ID, in.DeleteOutputs); err != nil {
			return nil, produceControlOut{}, d.produceErr(err)
		}
		return nil, produceControlOut{Status: "removed"}, nil
	}
	return nil, produceControlOut{}, fmt.Errorf("action %q: want resume, cancel or remove", in.Action)
}
