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

# The staging copy: its name belongs to this script, and a copy an interrupted
# run left behind may lack its Info.plist. Removed when it is a real directory
# that is ours or has no Info.plist at all; anything else is refused.
clear_staging() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        if [ -d "$1" ] && [ ! -L "$1" ] && { ours "$1" || [ ! -e "$1/Contents/Info.plist" ]; }; then
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
clear_ours "$old"
ditto "$src" "$new"

# Stop a running copy: its binary is about to be replaced. A signal, not an
# Apple Event, which would need the Automation permission for this terminal.
# The app gives a borrowed clipboard back on SIGTERM.
if pkill -x "$name"; then
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
# Installed either way; a failed start (no GUI session, e.g. over ssh) is not a
# failed install.
open "$dest" || echo "could not start $dest; open it from ~/Applications" >&2
