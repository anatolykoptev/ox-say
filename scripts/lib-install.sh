#!/usr/bin/env bash
# Shared steps of the two installers: scripts/install.sh (build from source) and
# scripts/install-release.sh (a prebuilt release). Source it; it defines the
# variables
#   label uid logdir plist
# and functions; oxs_settings also sets bindir, addr and home.
#
# launchd does not read your shell environment. Every OX_SAY_* variable the
# daemon reads (see `ox-say env-keys`) that is set when an installer runs is
# written into the LaunchAgent, so the daemon runs with the settings the
# installer used. On a re-run, those settings carry over from the installed
# agent unless set again; set one to an empty value to drop it. Paths must be
# absolute (the daemon's cwd is /).
#
# Variables that steer the installer itself are never written to the agent,
# because the daemon does not read them: OX_SAY_BINDIR (where the ox-say
# binary goes, default ~/.local/bin), OX_SAY_WITH_WHISPER (also fetch Whisper
# large-v3-turbo), OX_SAY_WITH_VOXCPM2 (also fetch the VoxCPM2 model; Apple
# Silicon with 24 GB or more), OX_SAY_MODELS_FROM (copy models from a local dir),
# OX_SAY_GET_URL, OX_SAY_NO_MCP, OX_SAY_NO_SELFTEST. The allowlist is the
# daemon's own env-keys table, not a hand-maintained list that can forget one.

label=io.github.anatolykoptev.ox-say
uid=$(id -u)
logdir="$HOME/Library/Logs/ox-say"
plist="$HOME/Library/LaunchAgents/$label.plist"

oxs_require() {
    local hint=$1 tool
    shift
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null; then
            echo "ox-say install: $tool not found ($hint)" >&2
            exit 1
        fi
    done
}

# oxs_env_keys holds the newline-separated names of the OX_SAY_* variables
# the daemon reads. oxs_settings and oxs_render_agent refuse to run before it
# is set: an empty allowlist would silently drop every carried-over setting.
oxs_env_keys=

oxs_env_keys_from() {
    oxs_env_keys=$("$1" env-keys)
}

oxs_env_keys_ready() {
    if [ -z "$oxs_env_keys" ]; then
        echo "ox-say install: run oxs_env_keys_from <ox-say binary> first" >&2
        exit 1
    fi
}

# Is $1 a variable the daemon reads (and therefore may reach the agent)?
oxs_daemon_var() {
    local k
    for k in $oxs_env_keys; do
        if [ "$k" = "$1" ]; then
            return 0
        fi
    done
    return 1
}

# Settings of the installed agent carry over unless set now; then every path
# setting must be absolute (the installer would resolve a relative one against
# the current directory, the daemon against /). Sets bindir, addr and home.
oxs_settings() {
    local name
    oxs_env_keys_ready
    if [ -f "$plist" ]; then
        for name in $(plutil -extract EnvironmentVariables xml1 -o - "$plist" 2>/dev/null |
            sed -n 's|.*<key>\(OX_SAY_[A-Z0-9_]*\)</key>.*|\1|p'); do
            if [ -n "${!name+set}" ]; then
                continue
            fi
            if oxs_daemon_var "$name"; then
                export "$name=$(plutil -extract "EnvironmentVariables.$name" raw -o - "$plist")"
                echo "keeping $name from the installed agent"
            else
                echo "dropping $name from the installed agent (the daemon does not read it)"
            fi
        done
    fi
    for name in $(compgen -e | grep '^OX_SAY_' || true); do
        case "$name" in
            # A model NAME, not a file: the engine to speak with (qwen3-tts or
            # voxcpm2). Every other *_MODEL key is a weights path (OX_SAY_MODEL,
            # OX_SAY_STT_MODEL, OX_SAY_STT_VAD_MODEL, OX_SAY_STT_WHISPER_MODEL,
            # OX_SAY_VOXCPM2_MODEL) and OX_SAY_CODEC a path too.
            OX_SAY_TTS_MODEL) ;;
            *_HOME | *_DIR | *_BIN | *_MODEL | *_CODEC | OX_SAY_BINDIR)
                if [ -n "${!name}" ] && [ "${!name#/}" = "${!name}" ]; then
                    echo "ox-say install: $name must be an absolute path (got '${!name}')" >&2
                    exit 2
                fi
                ;;
        esac
    done
    bindir=${OX_SAY_BINDIR:-"$HOME/.local/bin"}
    addr=${OX_SAY_ADDR:-127.0.0.1:8094}
    home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
}

# VoxCPM2 (OX_SAY_WITH_VOXCPM2=1) runs on Apple Silicon with >= 24 GB only (a
# 16 GB Mac is unmeasured; Metal wires at most about 2/3 of RAM): its 2B model
# sits next to the speech engines in unified memory. Elsewhere the opt-in is
# refused before any download.
oxs_voxcpm2_min_bytes=25769803776 # 24 GiB
oxs_voxcpm2_ok() {
    local mem
    if [ "$(uname -m)" != arm64 ]; then
        echo "ox-say: VoxCPM2 runs on Apple Silicon only; not fetching its model on this Mac" >&2
        return 1
    fi
    # Fail closed: no readable memory size is no proof of 24 GB.
    mem=$(sysctl -n hw.memsize 2>/dev/null) || mem=
    case $mem in
        '' | *[!0-9]*)
            echo "ox-say: cannot read this Mac's memory size; not fetching the VoxCPM2 model" >&2
            return 1
            ;;
    esac
    if [ "$mem" -lt "$oxs_voxcpm2_min_bytes" ]; then
        echo "ox-say: VoxCPM2 needs 24 GB of memory; this Mac has $((mem / 1073741824)) GB — not fetching its model" >&2
        return 1
    fi
}

oxs_fetch_models() {
    local fetch=$1 args=()
    if [ "${OX_SAY_WITH_WHISPER:-0}" = 1 ]; then
        args+=(--with-whisper)
    fi
    if [ "${OX_SAY_WITH_VOXCPM2:-0}" = 1 ] && oxs_voxcpm2_ok; then
        args+=(--with-voxcpm2)
    fi
    "$fetch" ${args[@]+"${args[@]}"}
}

# Render the LaunchAgent from its template into $2 — a path inside a temp dir
# the caller already made and trapped. Rendering into a caller-owned path, as
# a plain statement, keeps `set -e` working: inside `tmp=$(oxs_render_agent)`
# command substitution bash 3.2 has no inherit_errexit, so a failing plutil
# would not stop the installer. plutil does the XML escaping; the result is
# linted before the caller swaps it in. Only the variables the daemon reads
# are written — installer knobs must not ride into the agent's environment.
oxs_render_agent() {
    local template=$1 tmp=$2 name
    oxs_env_keys_ready
    mkdir -p "$(dirname "$plist")" "$logdir" "$bindir"
    cp "$template" "$tmp"
    # replace the whole array: -replace on an array index inserts instead of replacing
    plutil -replace ProgramArguments -array "$tmp"
    plutil -insert ProgramArguments -string "$bindir/ox-say" -append "$tmp"
    plutil -insert ProgramArguments -string serve -append "$tmp"
    plutil -replace StandardOutPath -string "$logdir/ox-say.log" "$tmp"
    plutil -replace StandardErrorPath -string "$logdir/ox-say.log" "$tmp"
    for name in $(compgen -e | grep '^OX_SAY_' || true); do
        if [ -z "${!name}" ] || ! oxs_daemon_var "$name"; then
            continue
        fi
        plutil -replace "EnvironmentVariables.$name" -string "${!name}" "$tmp"
    done
    plutil -lint "$tmp" >/dev/null
}

# Copy then rename, so a running process keeps its old inode.
oxs_install_engines() {
    local out=$1 bin lib
    for bin in tts-server ox-stt ox-align; do
        if [ ! -x "$out/$bin" ]; then
            echo "ox-say install: no $bin in $out" >&2
            exit 1
        fi
    done
    mkdir -p "$home/engine/licenses"
    # Each engine's precompiled Metal library travels next to it under its own
    # name (<bin>.metallib, plus <bin>-tensor.metallib on Metal4-capable
    # builds). The libraries go in before the binaries, but the window is
    # symmetric — an engine respawned mid-install meets a mismatched pair
    # either way, so the order buys nothing: what protects the engine is the
    # runtime guards (OS floor, bf16 and tensor kernels — the patched ggml
    # skips a library it cannot safely use) and the embedded shader sources
    # that keep an engine running with no library at all. A stale library left
    # by an older install must still go — the guards cannot tell it is stale.
    # The cleanup runs for audiocpp_server even when this package carries no
    # binary for it.
    for bin in tts-server ox-stt ox-align audiocpp_server; do
        for lib in "$bin.metallib" "$bin-tensor.metallib"; do
            if [ -f "$out/$lib" ]; then
                cp "$out/$lib" "$home/engine/$lib.new"
                mv "$home/engine/$lib.new" "$home/engine/$lib"
            else
                rm -f "$home/engine/$lib"
            fi
        done
        # Optional: only the arm64 package carries the VoxCPM2 server.
        [ -x "$out/$bin" ] || continue
        cp "$out/$bin" "$home/engine/$bin.new"
        mv "$home/engine/$bin.new" "$home/engine/$bin"
        echo "installed $home/engine/$bin"
    done
    cp "$out"/licenses/* "$home/engine/licenses/"
}

oxs_install_binary() {
    cp "$1" "$bindir/ox-say.new"
    mv "$bindir/ox-say.new" "$bindir/ox-say"
}

# Put the rendered agent in place and (re)load it.
oxs_load_agent() {
    mv "$1" "$plist"
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        # bootout returns before the old job has exited (ExitTimeOut 20 s); a
        # bootstrap before that fails with EIO.
        for _ in $(seq 1 100); do
            launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break
            sleep 0.5
        done
    fi
    launchctl bootstrap "gui/$uid" "$plist"
}

# Self-test verdict: does the transcript heard for the spoken phrase say that
# phrase? "Ready" must be one of its words AND the transcript must be no longer
# than the phrase plus two words (an ASR slip like "ox a" fits; a model that
# kept talking past the request - the continuation of its reference clip that
# happened to contain "ready" later - does not). Both sides are normalised the
# same way (lowercase, apostrophes and hyphens dropped, other punctuation to
# space), so "ox-say" is one word in the phrase and "oxsay", "ox say" or
# "Oxay" on the heard side stay within the two spare words.
# Usage: oxs_selftest_heard_ok <heard> <phrase>.
oxs_selftest_norm() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d "'-" | tr -c 'a-z0-9' ' '
}

oxs_selftest_heard_ok() {
    local heard=$1 phrase=$2 w n=0 phrase_n ready=0
    for w in $(oxs_selftest_norm "$heard"); do
        n=$((n + 1))
        [ "$w" = ready ] && ready=1
    done
    phrase_n=$(oxs_selftest_norm "$phrase" | wc -w | tr -d ' ')
    [ "$ready" = 1 ] && [ "$n" -le $((phrase_n + 2)) ]
}

# Wait for this version to answer, not a stale daemon on the same address.
oxs_wait_version() {
    local version=$1 got=
    for _ in $(seq 1 40); do
        got=$(curl -sf -m 2 "http://$addr/status" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)
        if [ "$got" = "$version" ]; then
            echo "ox-say $version is running on http://$addr"
            return 0
        fi
        sleep 0.5
    done
    echo "ox-say $version did not answer on http://$addr (answered: ${got:-nothing}); see $logdir/ox-say.log" >&2
    return 1
}
