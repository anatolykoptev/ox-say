#!/usr/bin/env bash
# Stop and remove the LaunchAgent and the ox-say binary. Engines, models and
# voices stay unless --purge is given. Paths are read back from the installed
# LaunchAgent, so an install with a custom OX_SAY_HOME or OX_SAY_BINDIR is
# removed correctly without setting them again.
set -euo pipefail

purge=0
for arg in "$@"; do
    case "$arg" in
        --purge) purge=1 ;;
        *)
            echo "usage: $0 [--purge]" >&2
            exit 2
            ;;
    esac
done

label=io.github.anatolykoptev.ox-say
plist="$HOME/Library/LaunchAgents/$label.plist"

bin="$HOME/.local/bin/ox-say"
home="$HOME/Library/Application Support/ox-say"
logdir="$HOME/Library/Logs/ox-say"
cachedir="$HOME/Library/Caches/ox-say"
if [ -f "$plist" ]; then
    get() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true; }
    v=$(get ProgramArguments.0) && [ -n "$v" ] && bin=$v
    v=$(get EnvironmentVariables.OX_SAY_HOME) && [ -n "$v" ] && home=$v
    v=$(get EnvironmentVariables.OX_SAY_CACHE_DIR) && [ -n "$v" ] && cachedir=$v
fi

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$plist" "$bin"
echo "ox-say agent and binary removed"

if [ "$purge" = 1 ]; then
    if [ "${home#/}" = "$home" ] || [ "${cachedir#/}" = "$cachedir" ]; then
        echo "refusing to purge relative paths: home '$home', cache '$cachedir'" >&2
        exit 2
    fi
    # Only what ox-say creates in its home, then rmdir: a home that holds
    # anything else is left in place.
    for d in engine models voices run; do
        if [ -d "$home/$d" ]; then
            rm -r "${home:?}/$d"
        fi
    done
    if [ -d "$home" ] && ! rmdir "$home" 2>/dev/null; then
        echo "left $home: it holds files ox-say did not create" >&2
    fi
    # Log and cache dirs only when they are ox-say's own (named ox-say).
    for d in "$logdir" "$cachedir"; do
        if [ -d "$d" ] && [ "$(basename "$d")" = ox-say ]; then
            rm -r "$d"
        elif [ -d "$d" ]; then
            echo "left $d: not an ox-say directory" >&2
        fi
    done
    echo "ox-say engines, models, voices, logs and cache removed"
fi
