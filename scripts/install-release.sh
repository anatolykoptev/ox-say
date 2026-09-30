#!/usr/bin/env bash
# Install an unpacked ox-say release for the current user. get.sh downloads,
# verifies and unpacks the release, then runs this from inside it:
#   <release>/bin/ox-say, <release>/engine/{tts-server,ox-stt,ox-align,licenses/},
#   <release>/launchd/, <release>/scripts/, <release>/VERSION
# Settings (OX_SAY_* variables): see scripts/lib-install.sh.
#   OX_SAY_NO_MCP=1       do not register the MCP server with Claude Code
#   OX_SAY_NO_SELFTEST=1  skip the speak-and-transcribe check at the end
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=scripts/lib-install.sh source-path=SCRIPTDIR
. "$root/scripts/lib-install.sh"

oxs_require "brew install ffmpeg" ffmpeg plutil launchctl curl shasum
version=$(cat "$root/VERSION")
# `ox-say env-keys` names the variables the daemon reads: it decides what
# oxs_settings carries over (fetch-models then sees a carried-over
# OX_SAY_HOME) and what the render writes into the LaunchAgent.
oxs_env_keys_from "$root/bin/ox-say"
oxs_settings

# 1. Fetch the models first: nothing the running daemon uses changes until step 2,
#    so a failed download leaves an installed version intact.
oxs_fetch_models "$root/scripts/fetch-models.sh"
# Caller-owned temp dir + plain-statement render: inside `tmp=$(oxs_render_agent)`
# command substitution bash 3.2 clears `set -e`, so a failing plutil would not
# stop the install.
tmpdir=$(mktemp -d)
tmp="$tmpdir/agent.plist"
trap 'rm -f "$tmp"; rmdir "$tmpdir" 2>/dev/null || true' EXIT
oxs_render_agent "$root/launchd/$label.plist.in" "$tmp"

# 2. Swap in the engines and the binary, then reload the agent.
oxs_install_engines "$root/engine"
oxs_install_binary "$root/bin/ox-say"
# get.sh deletes the extracted release tree, so the uninstaller must live
# under $OX_SAY_HOME.
cp "$root/scripts/uninstall.sh" "$home/uninstall.sh"
# Third-party licenses for the Go binary ship in the release under licenses/,
# next to the engine's own licenses dir.
if [ -d "$home/licenses" ]; then
    find "$home/licenses" -depth -delete
fi
cp -R "$root/licenses" "$home/"
oxs_load_agent "$tmp"
oxs_wait_version "$version"

# 3. Register the MCP server with Claude Code, if it is installed.
mcp_url="http://$addr/mcp"
if [ "${OX_SAY_NO_MCP:-0}" != 1 ] && command -v claude >/dev/null; then
    # remove+add, pinned to user scope: `mcp get` also reads project/local
    # scope from the cwd and would keep a stale URL on a changed OX_SAY_ADDR.
    claude mcp remove --scope user ox-say >/dev/null 2>&1 || true
    if claude mcp add --transport http --scope user ox-say "$mcp_url" >/dev/null; then
        echo "registered the MCP server ox-say with Claude Code ($mcp_url)"
    else
        echo "could not register the MCP server; run: claude mcp add --transport http --scope user ox-say $mcp_url" >&2
    fi
else
    echo "MCP: claude mcp add --transport http --scope user ox-say $mcp_url"
fi

# 4. Self-test: speak a phrase, transcribe it back. The first start of freshly
#    installed engines compiles their Metal shaders (about a minute on a
#    Radeon Pro 5500M), so this can take a while once.
if [ "${OX_SAY_NO_SELFTEST:-0}" != 1 ]; then
    echo "self-test: speaking and transcribing a phrase (the first run compiles GPU shaders, up to a few minutes)"
    st=$(mktemp -d)
    wav="$st/selftest.wav"
    heard=
    ok=0
    # no `| grep -q` here: under pipefail its early exit can SIGPIPE the writer
    # and fail a pipeline that matched
    if "$bindir/ox-say" say -o "$wav" "ox-say is ready" >/dev/null &&
        heard=$("$bindir/ox-say" transcribe "$wav"); then
        case "$(printf '%s' "$heard" | tr '[:upper:]' '[:lower:]')" in
            *ready*) ok=1 ;;
        esac
    fi
    rm -f "$wav"
    rmdir "$st"
    if [ "$ok" = 1 ]; then
        echo "self-test passed: heard \"$heard\""
    else
        echo "self-test failed (heard: \"${heard:-nothing}\"); see $logdir/ox-say.log" >&2
        exit 1
    fi
fi
echo "done. Try: ox-say say \"hello\"   ·   ox-say transcribe <file>   ·   ox-say status"
