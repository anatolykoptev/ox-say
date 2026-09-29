#!/usr/bin/env bash
# Build and install ox-say for the current user: engines, models, the ox-say
# binary and a LaunchAgent that keeps `ox-say serve` running.
#
# launchd does not read your shell environment. Every OX_SAY_* variable set when
# you run this script (OX_SAY_HOME, OX_SAY_ADDR, ...) is written into the
# LaunchAgent, so the daemon runs with the settings the installer used. On a
# re-run, settings of the installed agent carry over unless set again; set one
# to an empty value to drop it. Paths must be absolute (the daemon's cwd is /).
# These variables only steer the installer and never reach the agent:
#   OX_SAY_BINDIR        where the ox-say binary goes (default ~/.local/bin)
#   OX_SAY_WITH_WHISPER  1 also downloads Whisper large-v3-turbo (1.6 GB)
#   OX_SAY_MODELS_FROM   copy models from this dir instead of downloading
set -euo pipefail

for tool in go cmake ffmpeg plutil launchctl curl; do
    if ! command -v "$tool" >/dev/null; then
        echo "ox-say install: $tool not found (brew install cmake go ffmpeg)" >&2
        exit 1
    fi
done

root=$(cd "$(dirname "$0")/.." && pwd -P)
label=io.github.anatolykoptev.ox-say
uid=$(id -u)
bindir=${OX_SAY_BINDIR:-"$HOME/.local/bin"}
logdir="$HOME/Library/Logs/ox-say"
plist="$HOME/Library/LaunchAgents/$label.plist"
addr=${OX_SAY_ADDR:-127.0.0.1:8094}

installer_only() {
    case "$1" in
        OX_SAY_BINDIR | OX_SAY_WITH_WHISPER | OX_SAY_MODELS_FROM) return 0 ;;
    esac
    return 1
}

# Settings of the installed agent carry over unless set now.
if [ -f "$plist" ]; then
    for name in $(plutil -extract EnvironmentVariables xml1 -o - "$plist" 2>/dev/null |
        sed -n 's|.*<key>\(OX_SAY_[A-Z0-9_]*\)</key>.*|\1|p'); do
        if [ -z "${!name+set}" ]; then
            export "$name=$(plutil -extract "EnvironmentVariables.$name" raw -o - "$plist")"
            echo "keeping $name from the installed agent"
        fi
    done
fi

# Path settings must be absolute: the installer resolves a relative one against
# the current directory, the daemon against /.
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

version=dev
if command -v git >/dev/null && [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ]; then
    version=$(git -C "$root" describe --tags --always --dirty)
fi

# 1. Build and fetch everything first. Nothing the running daemon uses changes
#    until step 2, so a failure here leaves the installed version intact.
"$root/engine/build.sh"
if [ "${OX_SAY_WITH_WHISPER:-0}" = 1 ]; then
    "$root/scripts/fetch-models.sh" --with-whisper
else
    "$root/scripts/fetch-models.sh"
fi
mkdir -p "$root/build"
(cd "$root" && go build -trimpath -ldflags "-s -w -X main.version=$version" -o build/ox-say ./cmd/ox-say)

# The LaunchAgent is rendered with plutil (it does the XML escaping) into a
# temporary file outside LaunchAgents and linted before it replaces the
# installed one.
mkdir -p "$(dirname "$plist")" "$logdir" "$bindir"
tmpdir=$(mktemp -d)
trap 'rm -f "$tmpdir/agent.plist"; rmdir "$tmpdir" 2>/dev/null || true' EXIT
tmp="$tmpdir/agent.plist"
cp "$root/launchd/$label.plist.in" "$tmp"
# replace the whole array: -replace on an array index inserts instead of replacing
plutil -replace ProgramArguments -array "$tmp"
plutil -insert ProgramArguments -string "$bindir/ox-say" -append "$tmp"
plutil -insert ProgramArguments -string serve -append "$tmp"
plutil -replace StandardOutPath -string "$logdir/ox-say.log" "$tmp"
plutil -replace StandardErrorPath -string "$logdir/ox-say.log" "$tmp"
for name in $(compgen -e | grep '^OX_SAY_' || true); do
    if installer_only "$name" || [ -z "${!name}" ]; then
        continue
    fi
    plutil -replace "EnvironmentVariables.$name" -string "${!name}" "$tmp"
done
plutil -lint "$tmp" >/dev/null

# 2. Swap in the new engines and binary, then reload the agent.
"$root/scripts/install-engine.sh"
# Copy then rename: a running process keeps its old inode.
cp "$root/build/ox-say" "$bindir/ox-say.new"
mv "$bindir/ox-say.new" "$bindir/ox-say"
mv "$tmp" "$plist"

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

# 3. Wait for this build to answer, not a stale daemon on the same address.
got=
for _ in $(seq 1 40); do
    got=$(curl -sf -m 2 "http://$addr/status" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)
    if [ "$got" = "$version" ]; then
        echo "ox-say $version is running on http://$addr"
        echo "MCP: claude mcp add --transport http --scope user ox-say http://$addr/mcp"
        exit 0
    fi
    sleep 0.5
done
echo "ox-say $version did not answer on http://$addr (answered: ${got:-nothing}); see $logdir/ox-say.log" >&2
exit 1
