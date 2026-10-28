package daemon

import (
	"context"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// RegisterTools mounts the ox-say MCP tools on srv (the /mcp endpoint served
// by go-mcpserver). Every tool calls the same Go functions the HTTP handlers
// use — no loopback HTTP call to itself.
func (d *Daemon) RegisterTools(srv *mcp.Server) {
	mcp.AddTool(srv, &mcp.Tool{Name: "speak", Description: speakDescription}, d.toolSpeak)

	mcp.AddTool(srv, &mcp.Tool{
		Name: "voices_list",
		Description: `List saved voices: name, ref_text (the clip's transcript, when set), created, and when set engine ` +
			`(the voice's preferred model: "voxcpm2" or "qwen3-tts"), style (its default voxcpm2 delivery) and designed_from ` +
			`(the description a designed voice came from). Voices live on disk and are replayed into the engine on every start. ` +
			`Pass a name as speak's voice.`,
	}, d.toolVoicesList)

	mcp.AddTool(srv, &mcp.Tool{Name: "voice_add", Description: voiceAddDescription}, d.toolVoiceAdd)

	mcp.AddTool(srv, &mcp.Tool{
		Name: "voice_update",
		Description: `Change a saved voice's preferred engine ("", "qwen3-tts" or "voxcpm2") and/or its default style ` +
			`("" clears it) without re-adding the audio. Give only the fields to change; the rest stay. ` +
			`The style is the delivery speak uses when called with no instructions (voxcpm2), e.g. "calm and warm, slow". ` +
			`Switching to voxcpm2 needs a recording of at most 30 s; to make a new voice use voice_add or voice_design.`,
	}, d.toolVoiceUpdate)

	mcp.AddTool(srv, &mcp.Tool{
		Name: "voice_design",
		Description: `Create a NEW voice from a text description with the voxcpm2 engine (no reference audio). ` +
			`It renders ` + "`takes`" + ` candidate clips (default 3, max 4) of ` + "`text`" + ` with consecutive seeds and returns their paths and seeds. ` +
			`Compare them (listen, or transcribe to check clarity) and keep the best with voice_design_save {name, take: <take path>}; ` +
			`the saved voice keeps that timbre on every later line and records the description and seed. ` +
			`Describe the speaker: gender, age, pitch, timbre, pace, accent or "native <language> speaker", mood, and use. ` +
			`Example: "A clear, pleasant female narrator in her thirties, native Russian speaker, friendly and professional, audiobook style". ` +
			`Give 1-2 sentences of text in the target language (5-15 s spoken, at most 200 characters; it becomes the saved voice's transcript). ` +
			`seed (0-4294967295) is the first take's seed, the rest follow; the same seed gives the same take. ` +
			`After saving, speak with voice: <name>; speak's instructions still change its emotion. ` +
			`Each take takes about as long as it plays, plus up to 40 s if the model was idle. Takes are previews at the engine's own level. ` +
			`Apple Silicon with 24 GB or more only.`,
	}, d.toolVoiceDesign)

	mcp.AddTool(srv, &mcp.Tool{
		Name: "voice_design_save",
		Description: `Keep one take from voice_design as a named voice (engine voxcpm2). take must be a path voice_design returned; ` +
			`any other file is refused. The voice records the description, the seed and the take's text as its transcript.`,
	}, d.toolVoiceDesignSave)

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "voice_remove",
		Description: `Delete a saved voice from disk and from the running engine. Cannot be undone.`,
	}, d.toolVoiceRemove)

	mcp.AddTool(srv, &mcp.Tool{
		Name: "engine_status",
		Description: `Engine supervisors and config. engine = qwen3-tts; voxcpm2 = the studio voice (available, or the plain reason it is not: ` +
			`Intel Mac, not installed, too little memory; state stopped|starting|ready|crashed); stt_server = the resident transcriber. ` +
			`Each reports pid, uptime, last error and start/restart counts. Also lists voices, config and version. ` +
			`Check it when speak fails or voxcpm2 is slow: the first call after idle loads the model (10-40 s).`,
	}, d.toolEngineStatus)

	mcp.AddTool(srv, &mcp.Tool{
		Name: "transcribe",
		Description: `Transcribe a local audio file to text. Returns text plus audio duration, elapsed time and engine; ` +
			`words=true adds per-word timings. ` +
			`engine parakeet (default): fast, covers 25 European languages incl. English and Russian, language auto-detected. ` +
			`engine whisper: 99 languages, takes language and prompt hints; needs the optional whisper model. ` +
			`Parakeet word times carry about ±80 ms jitter — for cut-precise timings use a forced aligner on the transcript instead. ` +
			`out_path writes the full result JSON (segments and words) to an absolute .json path.`,
	}, d.toolTranscribe)

	d.registerProduceTools(srv)
	d.registerMeetingTools(srv)
}

type speakToolIn struct {
	Text               string   `json:"text" jsonschema:"Text to speak (qwen3-tts: max 5000 chars; voxcpm2: max 1000)"`
	Model              string   `json:"model,omitempty" jsonschema:"\"qwen3-tts\" or \"voxcpm2\"; omit for the voice's or the daemon's default"`
	Voice              string   `json:"voice,omitempty" jsonschema:"Saved voice name; \"default\" = no cloned voice (needed for voice design); omit for the configured default voice"`
	Language           string   `json:"language,omitempty" jsonschema:"Language name (e.g. Russian, English); voxcpm2 detects it from the text"`
	Format             string   `json:"format,omitempty" jsonschema:"wav (default) | mp3 | opus (Ogg container, Telegram-ready)"`
	OutPath            string   `json:"out_path,omitempty" jsonschema:"Absolute output path; parent must exist; extension must match format; existing file refused unless overwrite"`
	Overwrite          bool     `json:"overwrite,omitempty" jsonschema:"Allow replacing an existing out_path file"`
	Play               bool     `json:"play,omitempty" jsonschema:"Play the audio after writing (macOS afplay)"`
	Instructions       string   `json:"instructions,omitempty" jsonschema:"voxcpm2: how to speak, short English descriptors without parentheses (emotion, pace, loudness, delivery); with voice \"default\" it also describes the speaker"`
	CfgValue           *float64 `json:"cfg_value,omitempty" jsonschema:"voxcpm2 guidance, above 0 and at most 5, default 2.0 (measured); raise only if a take ignores the style"`
	InferenceTimesteps *int     `json:"inference_timesteps,omitempty" jsonschema:"voxcpm2 diffusion steps, whole number 1-50, default 10 (measured); more is slower"`
	CloneMode          string   `json:"clone_mode,omitempty" jsonschema:"voxcpm2: auto (default; faithful copy only if the voice has ref_text, no style at all and same-script text) / reference (timbre only, styles allowed) / ultimate (needs ref_text and no style: refused with instructions or a saved voice style)"`
	Seed               *int64   `json:"seed,omitempty" jsonschema:"0-4294967295; reproduces a take; the result reports the seed used"`
	LoudnessLUFS       *float64 `json:"loudness_lufs,omitempty" jsonschema:"Normalize integrated loudness (-40..-5), e.g. -16 (online video), -23 (broadcast)"`
}

func (d *Daemon) toolSpeak(ctx context.Context, _ *mcp.CallToolRequest, in speakToolIn) (*mcp.CallToolResult, SpeakResult, error) {
	defer d.beginInteractive()()
	res, err := d.Speak(ctx, SpeakInput{
		Text:               in.Text,
		Voice:              in.Voice,
		Language:           in.Language,
		Format:             in.Format,
		OutPath:            in.OutPath,
		Overwrite:          in.Overwrite,
		Play:               in.Play,
		Instructions:       in.Instructions,
		Seed:               in.Seed,
		LoudnessLUFS:       in.LoudnessLUFS,
		Model:              in.Model,
		CfgValue:           in.CfgValue,
		InferenceTimesteps: in.InferenceTimesteps,
		CloneMode:          in.CloneMode,
	})
	if err != nil {
		return nil, SpeakResult{}, err
	}
	return nil, *res, nil
}

type voicesListOut struct {
	Voices []voiceOut `json:"voices"`
}

type voiceOut struct {
	Name         string `json:"name"`
	RefText      string `json:"ref_text,omitempty"`
	Created      string `json:"created"`
	Engine       string `json:"engine,omitempty"`
	Style        string `json:"style,omitempty"`
	DesignedFrom string `json:"designed_from,omitempty"`
}

func (d *Daemon) toolVoicesList(_ context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, voicesListOut, error) {
	list, err := d.Store.List()
	if err != nil {
		return nil, voicesListOut{}, err
	}
	out := voicesListOut{Voices: make([]voiceOut, 0, len(list))}
	for _, v := range list {
		out.Voices = append(out.Voices, newVoiceOut(v))
	}
	return nil, out, nil
}

type voiceAddIn struct {
	Name      string `json:"name" jsonschema:"Voice name: ^[a-z0-9][a-z0-9_-]{0,31}$"`
	AudioPath string `json:"audio_path" jsonschema:"Local path to a 5-20 s clean voice clip (a longer one is cut at a word boundary and ref_text is replaced by the transcript of the kept part) (any format ffmpeg reads)"`
	RefText   string `json:"ref_text,omitempty" jsonschema:"Transcript of the clip — only for same-language cloning; omit for other languages"`
	// Engine, Style and DesignedFrom are the voice's metadata; all optional.
	Engine       string `json:"engine,omitempty" jsonschema:"Preferred model for this voice: voxcpm2 or qwen3-tts; empty = the daemon default"`
	Style        string `json:"style,omitempty" jsonschema:"Default voxcpm2 delivery used when speak has no instructions, e.g. calm and warm, slow"`
	DesignedFrom string `json:"designed_from,omitempty" jsonschema:"Note of how the voice was made, e.g. the description of a designed voice"`
}

type voiceAddOut struct {
	Name               string `json:"name"`
	RegisteredToEngine bool   `json:"registered_to_engine"`
	Notice             string `json:"notice,omitempty"`
}

func (d *Daemon) toolVoiceAdd(ctx context.Context, _ *mcp.CallToolRequest, in voiceAddIn) (*mcp.CallToolResult, voiceAddOut, error) {
	v, registered, err := d.AddVoiceMeta(ctx, in.Name, in.AudioPath, in.RefText,
		voices.Meta{Engine: in.Engine, Style: in.Style, DesignedFrom: in.DesignedFrom})
	if err != nil {
		return nil, voiceAddOut{}, err
	}
	return nil, voiceAddOut{Name: v.Name, RegisteredToEngine: registered, Notice: v.Notice}, nil
}

type voiceUpdateIn struct {
	Name   string  `json:"name" jsonschema:"Name of the saved voice"`
	Engine *string `json:"engine,omitempty" jsonschema:"Preferred model: voxcpm2, qwen3-tts, or empty for the daemon default; omit to leave it"`
	Style  *string `json:"style,omitempty" jsonschema:"Default voxcpm2 delivery; empty string clears it; omit to leave it"`
}

func (d *Daemon) toolVoiceUpdate(_ context.Context, _ *mcp.CallToolRequest, in voiceUpdateIn) (*mcp.CallToolResult, voiceOut, error) {
	v, err := d.UpdateVoice(in.Name, in.Engine, in.Style)
	if err != nil {
		return nil, voiceOut{}, d.publicError(err)
	}
	return nil, newVoiceOut(*v), nil
}

// newVoiceOut is the agent-facing view of a stored voice.
func newVoiceOut(v voices.Voice) voiceOut {
	return voiceOut{
		Name:         v.Name,
		RefText:      v.RefText,
		Created:      v.Created.Format("2006-01-02T15:04:05Z"),
		Engine:       v.Engine,
		Style:        v.Style,
		DesignedFrom: v.DesignedFrom,
	}
}

type voiceRemoveIn struct {
	Name string `json:"name" jsonschema:"Voice name to delete"`
}

func (d *Daemon) toolVoiceRemove(ctx context.Context, _ *mcp.CallToolRequest, in voiceRemoveIn) (*mcp.CallToolResult, struct{}, error) {
	if err := d.RemoveVoice(ctx, in.Name); err != nil {
		return nil, struct{}{}, err
	}
	return nil, struct{}{}, nil
}

func (d *Daemon) toolEngineStatus(_ context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, statusSummary, error) {
	return nil, d.Status(), nil
}

func (d *Daemon) toolVoiceDesign(ctx context.Context, _ *mcp.CallToolRequest, in DesignInput) (*mcp.CallToolResult, DesignResult, error) {
	res, err := d.DesignVoice(ctx, in)
	if err != nil {
		return nil, DesignResult{}, d.publicError(err)
	}
	return nil, *res, nil
}

func (d *Daemon) toolVoiceDesignSave(ctx context.Context, _ *mcp.CallToolRequest, in SaveDesignInput) (*mcp.CallToolResult, SaveDesignResult, error) {
	res, err := d.saveDesignResult(ctx, in)
	if err != nil {
		return nil, SaveDesignResult{}, d.publicError(err)
	}
	return nil, *res, nil
}
