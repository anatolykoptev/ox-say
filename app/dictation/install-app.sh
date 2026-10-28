#!/usr/bin/env bash
# Install OxSayDictation.app into a directory (default ~/Applications) and start it.
#
#   install-app.sh <OxSayDictation.app> [dir]    install, replacing an older copy
#   install-app.sh --check [dir]                  only check that an existing copy may be replaced
#
# An existing bundle is replaced only when it is a real directory whose
# Info.plist carries our bundle identifier; anything else at that path is not
# ours to delete. The new copy is staged next to the old one and swapped in
# with renames, so a failure never leaves a half-deleted app behind.
# Used by app/dictation/build.sh --install and by the release installer.
#
# OX_SAY_APP_RELAUNCHES=1 (set by the app when it starts the install): the
# running app relaunches itself once it is idle, so this script neither stops
# it nor starts the new copy. The swap is still done here; replacing the bundle
# of a running app by rename is safe, the process keeps its mapped files.
set -euo pipefail

name=OxSayDictation
bundle_id=io.github.anatolykoptev.ox-say.dictation

check=0
if [ "${1:-}" = --check ]; then
    check=1
    shift
else
    src=${1:?usage: $0 <OxSayDictation.app> [dir] | $0 --check [dir]}
    shift
fi
dir=${1:-$HOME/Applications}
dest=$dir/$name.app
new=$dir/.$name.app.new
old=$dir/.$name.app.old

ours() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true)" = "$bundle_id" ]
}

# A bundle an interrupted copy or removal left half done: no Info.plist, and
# nothing in the directory but Contents and Finder's .DS_Store (or nothing at
# all). A directory that holds anything else under a name of ours is not a
# bundle remnant.
partial_bundle() {
    local f
    [ -d "$1" ] && [ ! -L "$1" ] && [ ! -e "$1/Contents/Info.plist" ] || return 1
    # A glob loop, not `ls -A | grep -vx`: the three patterns together name every entry but . and .., and a name is
    # compared as a string (a grep pattern's dot would take "xDS_Store" for Finder's file). An unmatched pattern
    # stays literal, hence the existence test.
    for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case ${f##*/} in
            Contents | .DS_Store) ;;
            *) return 1 ;;
        esac
    done
}

# The two staging copies, .new and .old: their names belong to this script, and
# a copy an interrupted run left behind may lack its Info.plist (a half-made
# .new, or a .old whose removal was cut off). Removed when it is a real
# directory that is ours or a partial bundle; anything else is refused.
clear_staging() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        if [ -d "$1" ] && [ ! -L "$1" ] && { ours "$1" || partial_bundle "$1"; }; then
            rm -r "$1"
        else
            echo "install-app.sh: $1 is not an OxSay Dictation staging copy; not replacing it" >&2
            exit 1
        fi
    fi
}

# Leaves $1 absent, removing it only if it is one of our bundles.
clear_ours() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        if ! ours "$1"; then
            echo "install-app.sh: $1 is not an OxSay Dictation bundle; not replacing it" >&2
            exit 1
        fi
        rm -r "$1"
    fi
}

if [ -e "$dest" ] || [ -L "$dest" ]; then
    if ! ours "$dest"; then
        echo "install-app.sh: $dest is not an OxSay Dictation bundle; not replacing it" >&2
        exit 1
    fi
fi
[ "$check" = 1 ] && exit 0

if ! ours "$src"; then
    echo "install-app.sh: $src is not an OxSay Dictation bundle" >&2
    exit 1
fi

mkdir -p "$dir"
clear_staging "$new"
clear_staging "$old"
ditto "$src" "$new"

app_relaunches=0
[ "${OX_SAY_APP_RELAUNCHES:-0}" = 1 ] && app_relaunches=1

# Stop a running copy: its binary is about to be replaced. A signal, not an
# Apple Event, which would need the Automation permission for this terminal.
# The app gives a borrowed clipboard back on SIGTERM. Not when the app started
# this install: it may be mid-dictation and ends itself when idle.
if [ "$app_relaunches" = 0 ] && pkill -x "$name"; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$name" >/dev/null || break
        sleep 0.5
    done
fi

if [ -e "$dest" ]; then
    mv "$dest" "$old"
fi
mv "$new" "$dest"
clear_ours "$old"
echo "installed $dest"
if [ "$app_relaunches" = 1 ]; then
    echo "the running OxSay Dictation will relaunch itself when it is idle"
    exit 0
fi
# Installed either way; a failed start (no GUI session, e.g. over ssh) is not a
# failed install.
open "$dest" || echo "could not start $dest; open it from ~/Applications" >&2
