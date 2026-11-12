# MCP
The same server exposes MCP tools on `/mcp`: `speak`, `transcribe`,
`voices_list`, `voice_add`, `voice_update`, `voice_remove`, `voice_design`, `voice_design_save`,
`engine_status`, the long-form voiceover tools `produce`, `produce_status`, `produce_edit`, `produce_control`,
three read-only meeting tools: `meetings_list`, `meeting_get` (notes and/or transcript, paged) and
`meetings_search`, and the offline voice-cleanup tool `voice_clean` (the same code as `POST /v1/audio/clean`: it refuses
the meetings store, fetches the model on first use, and answers with the plain sentence and stable code when it is busy). Each tool's description tells an agent when to use it, the units and limits, and what
to call next; the VoxCPM2 quality options (`model`, `instructions`, `cfg_value`, `inference_timesteps`,
`seed`, `loudness_lufs`) are on `speak` only, and `clone_mode` is on `speak` and `produce` (the same
`auto`/`reference`/`ultimate` set, judged by the same rules). Register with:

```
claude mcp add --transport http --scope user ox-say http://127.0.0.1:8094/mcp
```

