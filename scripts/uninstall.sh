#!/usr/bin/env bash
# Stop and remove the LaunchAgent, the ox-say binary and the dictation app in
# ~/Applications. Engines, models and voices stay unless --purge is given. Paths are read back from the installed
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

# The dictation app, only when the bundle at that path is ours.
app="$HOME/Applications/OxSayDictation.app"
if [ -d "$app" ] && [ ! -L "$app" ] &&
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)" = "$label.dictation" ]; then
    if pkill -x OxSayDictation; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x OxSayDictation >/dev/null || break
            sleep 0.5
        done
    fi
    rm -r "$app"
    echo "OxSay Dictation removed"
fi

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
    # The release installer copies this script to $home/uninstall.sh; remove
    # it so rmdir can drop an otherwise-empty home. Unlinking the running
    # script is safe — the open fd keeps the inode until exit.
    rm -f "$home/uninstall.sh"
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
