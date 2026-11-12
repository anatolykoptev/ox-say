# Install

## The installer

curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh
```

The installer:
- downloads a prebuilt release and checks its SHA-256;
- fetches the models, checksummed: about 2.5 GB on Apple Silicon, including 221 MB of
  speaker models for [Meetings](meetings.md) (the 199 MB Nemotron set is fetched whatever the macOS version, so a
  Mac that upgrades to macOS 15 later already has it), and about 2.3 GB on an Intel Mac, which skips that set. The optional Whisper adds 1.6 GB. The meeting-notes model is not part of it: it
  is downloaded when you first ask for notes (5.7 GB for the default 9B on a Mac with 24 GB or more, 2.7 GB for the 4B that 16–23 GB Macs use);
- starts the daemon as a LaunchAgent;
- registers the MCP server with Claude Code, if Claude Code is installed;
- runs a speak-and-transcribe self-test;
- installs the dictation app into `~/Applications` and starts it
  (`OX_SAY_NO_DICTATION=1` skips it).

It needs `ffmpeg` (`brew install ffmpeg`) and never uses `sudo`. To build from source instead, run
`scripts/install.sh` (it needs Xcode CLT, `go`, `cmake` and `ffmpeg`).

**Install through your coding agent.** Paste this into Claude Code, Codex or Cursor:

> Install ox-say on this Mac with `curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh`,
> then show me `ox-say status` and speak one sentence with `ox-say say`.

## From source

Requirements: macOS 14.2 or later on Apple Silicon, or on an Intel Mac with AVX2; Xcode command line tools, CMake, Go, ffmpeg
(`brew install cmake go ffmpeg`).
Telling the voices of a group call apart (`ox-diar`) needs macOS 15 or later on Apple Silicon; building it from source also needs Xcode 26 (Swift 6.2).
A source install on an older Mac or with older tools skips it and meetings come out with one label for the other side
(`OX_SAY_WITH_DIAR=1` builds it anyway; the Apple Silicon release package carries it, the Intel one does not).

```
scripts/install.sh      # engines + models + ox-say + LaunchAgent, then waits for /health
claude mcp add --transport http --scope user ox-say http://127.0.0.1:8094/mcp
```

It installs `ox-say` into `~/.local/bin` (`OX_SAY_BINDIR` overrides; keep it on
your `PATH` for the CLI), the engines and models into
`~/Library/Application Support/ox-say`, logs into `~/Library/Logs/ox-say`, and
the LaunchAgent `io.github.anatolykoptev.ox-say`, which keeps `ox-say serve`
running. The agent is an Interactive launchd job: the daemon and its engines run at
an app's base CPU priority (31) instead of launchd's throttled default (20),
still below the app in front and the window server.
`OX_SAY_WITH_WHISPER=1 scripts/install.sh` also fetches Whisper
large-v3-turbo.
`OX_SAY_WITH_VOXCPM2=1 scripts/install.sh` also builds audio.cpp's server and
fetches the VoxCPM2 model (Q8_0, about 3 GB), the quality text-to-speech engine.
It needs Apple Silicon with 24 GB of memory or more: elsewhere the installer
says so and fetches nothing. Without the variable a source install does not
build the engine at all; a release package for Apple Silicon always carries the
binary, and the same variable fetches the model.

launchd does not read your shell environment: set any `OX_SAY_*` configuration
(see below) when you run the installer, e.g.
`OX_SAY_IDLE_STOP_SECS=600 scripts/install.sh`, and it is written into the
LaunchAgent. Path settings must be absolute. Re-running the installer upgrades
in place; settings of the installed agent carry over unless you set them again
(an empty value drops one). The `ox-say` CLI reads `OX_SAY_ADDR` from your shell,
so export it there too if you installed the daemon on a custom address.

`~/Library/Application Support/ox-say/uninstall.sh` (installed there by the
release installer; in a source checkout it is `scripts/uninstall.sh`) removes
the agent, the binary and the dictation app, and keeps engines, models and
voices; `--purge` removes those too. Undo the MCP registration with
`claude mcp remove --scope user ox-say`.

