package daemon

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The voice_clean tool is a thin face on Daemon.Clean, the same call the HTTP route makes: the same Forbidden meetings
// directory, quiet wait, GPU turns, lazy model download and error mapping. Nothing here runs a tool of its own.

// cleanToolDescription is load-bearing (tested): an agent decides from it whether the tool fits the file.
const cleanToolDescription = `Clean up the voice track of a local video or audio file offline (noise, room, other sounds under the voice) with a Core ML speech-enhancement model; ` +
	`replaces only the first audio stream and copies every other stream, metadata and chapters unchanged. Fully offline, ` +
	`about 170x real time on Apple Silicon; slower on Intel Macs (about 7x with a discrete GPU), which are supported. ` +
	`NOT for meetings or dictation: it refuses files inside the meetings store. Needs ffmpeg. ` +
	`in_path and out_path are absolute and the input is never changed: a video in gives a video out (.mov .mp4 .m4v .mkv .webm), ` +
	`audio in gives .wav .flac .mp3 or .m4a. Existing out_path is refused unless overwrite. ` +
	`wet is the share of the cleaned voice (default 0.85: 15 % of the original stays in). ` +
	`One file at a time: busy means another is being cleaned or the Mac is occupied, try again; models_downloading means the model (about 131 MB) is being fetched on first use. ` +
	`The answer reports lag_ms (the measured picture-to-sound shift) and dropped (input streams the output leaves out).`

type cleanToolIn struct {
	InPath    string   `json:"in_path" jsonschema:"Absolute path of the video or audio file to clean; never changed"`
	OutPath   string   `json:"out_path" jsonschema:"Absolute path of the result; parent must exist; video in gives .mov .mp4 .m4v .mkv .webm, audio in gives .wav .flac .mp3 .m4a; existing file refused unless overwrite"`
	Wet       *float64 `json:"wet,omitempty" jsonschema:"Share of the cleaned voice, 0 to 1; default 0.85 (15 % of the original stays in); 0 returns the input unchanged"`
	Stereo    string   `json:"stereo,omitempty" jsonschema:"mid (default) | channels: how a stereo file is cleaned"`
	Overwrite bool     `json:"overwrite,omitempty" jsonschema:"Allow replacing an existing out_path file"`
}

// cleanToolSchema is the inferred schema with the one bound a struct tag cannot express: wet in 0..1.
func cleanToolSchema() (*jsonschema.Schema, error) {
	s, err := jsonschema.For[cleanToolIn](nil)
	if err != nil {
		return nil, err
	}
	zero, one := 0.0, 1.0
	wet := s.Properties["wet"]
	if wet == nil {
		return nil, errors.New("voice_clean: no wet property in the schema")
	}
	wet.Minimum, wet.Maximum = &zero, &one
	return s, nil
}

func (d *Daemon) registerCleanTools(srv *mcp.Server) {
	schema, err := cleanToolSchema()
	if err != nil {
		panic(err) // a static type: failing here is a programming error caught by every test that registers tools
	}
	mcp.AddTool(srv, &mcp.Tool{Name: "voice_clean", Description: cleanToolDescription, InputSchema: schema}, d.toolVoiceClean)
}

func (d *Daemon) toolVoiceClean(ctx context.Context, _ *mcp.CallToolRequest, in cleanToolIn) (*mcp.CallToolResult, CleanResult, error) {
	res, err := d.Clean(ctx, CleanInput{InPath: in.InPath, OutPath: in.OutPath, Wet: in.Wet, Stereo: in.Stereo, Overwrite: in.Overwrite})
	if err != nil {
		return nil, CleanResult{}, d.cleanToolError(err)
	}
	return nil, *res, nil
}

// cleanToolError is what the agent reads: the plain sentence and the stable code, never the engine's stderr, its
// reason token or any tool output (those stay in the daemon log).
func (d *Daemon) cleanToolError(err error) error {
	var ce *CleanError
	if errors.As(err, &ce) {
		return fmt.Errorf("%s (%s)", ce.Msg, ce.Code)
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err // the caller left or its deadline ran out: no tool output in it
	}
	d.log.Warn("voice cleanup tool failed", "error", err)
	return errors.New("Voice cleanup failed. Details are in the ox-say log.")
}
