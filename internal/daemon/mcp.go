package daemon

import (
	"context"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// RegisterTools mounts the ox-say MCP tools on srv (the /mcp endpoint served
// by go-mcpserver). Every tool calls the same Go functions the HTTP handlers
// use — no loopback HTTP call to itself.
func (d *Daemon) RegisterTools(srv *mcp.Server) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "speak",
		Description: `Synthesize text to speech and write an audio file. Returns the file path, format, audio duration and elapsed time. ` +
			`The engine cold-starts on first call after idle — expect several seconds while the model loads. ` +
			`Use a cloned voice via the voice argument (see voice_add): voices are cloned from a 5-20 s clean clip. ` +
			`When synthesizing a language different from the clip's, the voice should have been added WITHOUT ref_text — ` +
			`that clones timbre only and avoids carrying the clip's accent. ` +
			`format wav (default) | mp3 | opus (opus is OGG-encapsulated, ready for Telegram voice notes). ` +
			`Without out_path the file goes to the daemon cache dir as <timestamp>-<slug>.<ext>; ` +
			`with out_path it must be absolute with an existing parent and a format-matching extension — ` +
			`an existing file is refused unless overwrite is true. play=true plays the result after writing.`,
	}, d.toolSpeak)

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "voices_list",
		Description: `List persisted cloned voices (name, ref_text, created). Voices live on disk and are replayed into the engine on every start.`,
	}, d.toolVoicesList)

	mcp.AddTool(srv, &mcp.Tool{
		Name: "voice_add",
		Description: `Clone a voice from a local audio file: 5-20 s of clean single-speaker audio works best; ` +
			`the clip is normalized to 24 kHz mono WAV automatically. ` +
			`Set ref_text to the clip's transcript for transcript-conditioned cloning of the clip's OWN language — ` +
			`it improves quality but carries the accent. For OTHER languages omit ref_text (timbre-only cloning). ` +
			`name must match ^[a-z0-9][a-z0-9_-]{0,31}$.`,
	}, d.toolVoiceAdd)

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "voice_remove",
		Description: `Delete a cloned voice from disk and from the running engine.`,
	}, d.toolVoiceRemove)

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "engine_status",
		Description: `Engine supervisor status: state (stopped|starting|ready|crashed), pid, uptime, last error, start/restart counts.`,
	}, d.toolEngineStatus)
}

type speakToolIn struct {
	Text         string `json:"text" jsonschema:"Text to synthesize (required, max 5000 chars)"`
	Voice        string `json:"voice,omitempty" jsonschema:"Cloned voice name; omit for the engine default"`
	Language     string `json:"language,omitempty" jsonschema:"Language name (e.g. Russian, English); empty = engine auto-detect"`
	Format       string `json:"format,omitempty" jsonschema:"wav (default) | mp3 | opus (Ogg container, Telegram-ready)"`
	OutPath      string `json:"out_path,omitempty" jsonschema:"Absolute output path; parent must exist; extension must match format; existing file refused unless overwrite"`
	Overwrite    bool   `json:"overwrite,omitempty" jsonschema:"Allow replacing an existing out_path file"`
	Play         bool   `json:"play,omitempty" jsonschema:"Play the audio after writing (macOS afplay)"`
	Instructions string `json:"instructions,omitempty" jsonschema:"Style/emotion steering for the synthesis"`
	Seed         *int64 `json:"seed,omitempty" jsonschema:"Random seed for reproducible output"`
}

func (d *Daemon) toolSpeak(ctx context.Context, _ *mcp.CallToolRequest, in speakToolIn) (*mcp.CallToolResult, SpeakResult, error) {
	res, err := d.Speak(ctx, SpeakInput{
		Text:         in.Text,
		Voice:        in.Voice,
		Language:     in.Language,
		Format:       in.Format,
		OutPath:      in.OutPath,
		Overwrite:    in.Overwrite,
		Play:         in.Play,
		Instructions: in.Instructions,
		Seed:         in.Seed,
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
	Name    string `json:"name"`
	RefText string `json:"ref_text,omitempty"`
	Created string `json:"created"`
}

func (d *Daemon) toolVoicesList(_ context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, voicesListOut, error) {
	list, err := d.Store.List()
	if err != nil {
		return nil, voicesListOut{}, err
	}
	out := voicesListOut{Voices: make([]voiceOut, 0, len(list))}
	for _, v := range list {
		out.Voices = append(out.Voices, voiceOut{
			Name:    v.Name,
			RefText: v.RefText,
			Created: v.Created.Format("2006-01-02T15:04:05Z"),
		})
	}
	return nil, out, nil
}

type voiceAddIn struct {
	Name      string `json:"name" jsonschema:"Voice name: ^[a-z0-9][a-z0-9_-]{0,31}$"`
	AudioPath string `json:"audio_path" jsonschema:"Local path to a 5-20 s clean voice clip (any format ffmpeg reads)"`
	RefText   string `json:"ref_text,omitempty" jsonschema:"Transcript of the clip — only for same-language cloning; omit for other languages"`
}

type voiceAddOut struct {
	Name               string `json:"name"`
	RegisteredToEngine bool   `json:"registered_to_engine"`
}

func (d *Daemon) toolVoiceAdd(ctx context.Context, _ *mcp.CallToolRequest, in voiceAddIn) (*mcp.CallToolResult, voiceAddOut, error) {
	v, registered, err := d.AddVoice(ctx, in.Name, in.AudioPath, in.RefText)
	if err != nil {
		return nil, voiceAddOut{}, err
	}
	return nil, voiceAddOut{Name: v.Name, RegisteredToEngine: registered}, nil
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
