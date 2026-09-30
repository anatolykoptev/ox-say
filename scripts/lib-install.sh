#!/usr/bin/env bash
# Shared steps of the two installers: scripts/install.sh (build from source) and
# scripts/install-release.sh (a prebuilt release). Source it; it defines functions
# and these variables:
#   label uid bindir logdir plist addr home
#
# launchd does not read your shell environment. Every OX_SAY_* variable set when
# an installer runs (OX_SAY_HOME, OX_SAY_ADDR, ...) is written into the
# LaunchAgent, so the daemon runs with the settings the installer used. On a
# re-run, settings of the installed agent carry over unless set again; set one
# to an empty value to drop it. Paths must be absolute (the daemon's cwd is /).
# These variables only steer the installer and never reach the agent:
#   OX_SAY_BINDIR        where the ox-say binary goes (default ~/.local/bin)
#   OX_SAY_WITH_WHISPER  1 also downloads Whisper large-v3-turbo (1.6 GB)
#   OX_SAY_MODELS_FROM   copy models from this dir instead of downloading

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

oxs_installer_only() {
    case "$1" in
        OX_SAY_BINDIR | OX_SAY_WITH_WHISPER | OX_SAY_MODELS_FROM) return 0 ;;
    esac
    return 1
}

# Settings of the installed agent carry over unless set now; then every path
# setting must be absolute (the installer would resolve a relative one against
# the current directory, the daemon against /). Sets bindir, addr and home.
oxs_settings() {
    local name
    if [ -f "$plist" ]; then
        for name in $(plutil -extract EnvironmentVariables xml1 -o - "$plist" 2>/dev/null |
            sed -n 's|.*<key>\(OX_SAY_[A-Z0-9_]*\)</key>.*|\1|p'); do
            if [ -z "${!name+set}" ]; then
                export "$name=$(plutil -extract "EnvironmentVariables.$name" raw -o - "$plist")"
                echo "keeping $name from the installed agent"
            fi
        done
    fi
    for name in $(compgen -e | grep '^OX_SAY_' || true); do
        case "$name" in
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

oxs_fetch_models() {
    local fetch=$1
    if [ "${OX_SAY_WITH_WHISPER:-0}" = 1 ]; then
        "$fetch" --with-whisper
    else
        "$fetch"
    fi
}

# Render the LaunchAgent from its template with plutil (it does the XML
# escaping) into a temporary file outside LaunchAgents, and lint it before it
# replaces the installed one. Prints the temporary file's path; the caller
# removes its directory.
oxs_render_agent() {
    local template=$1 tmpdir tmp name
    mkdir -p "$(dirname "$plist")" "$logdir" "$bindir"
    tmpdir=$(mktemp -d)
    tmp="$tmpdir/agent.plist"
    cp "$template" "$tmp"
    # replace the whole array: -replace on an array index inserts instead of replacing
    plutil -replace ProgramArguments -array "$tmp"
    plutil -insert ProgramArguments -string "$bindir/ox-say" -append "$tmp"
    plutil -insert ProgramArguments -string serve -append "$tmp"
    plutil -replace StandardOutPath -string "$logdir/ox-say.log" "$tmp"
    plutil -replace StandardErrorPath -string "$logdir/ox-say.log" "$tmp"
    for name in $(compgen -e | grep '^OX_SAY_' || true); do
        if oxs_installer_only "$name" || [ -z "${!name}" ]; then
            continue
        fi
        plutil -replace "EnvironmentVariables.$name" -string "${!name}" "$tmp"
    done
    plutil -lint "$tmp" >/dev/null
    echo "$tmp"
}

# Copy then rename, so a running process keeps its old inode.
oxs_install_engines() {
    local out=$1 bin
    for bin in tts-server ox-stt ox-align; do
        if [ ! -x "$out/$bin" ]; then
            echo "ox-say install: no $bin in $out" >&2
            exit 1
        fi
    done
    mkdir -p "$home/engine/licenses"
    for bin in tts-server ox-stt ox-align; do
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
