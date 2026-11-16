#!/bin/sh
# Publishes the macOS floor of a release in its notes (#494): appends one hidden line,
#   <!-- ox-say-min-macos: 14.2 -->
# to <notes-file>, with the floor read from the packaged app's LSMinimumSystemVersion (the value
# the signed bundle really carries, not a second literal). The in-app updater reads the line from
# the release body and tells a Mac below the floor why it is not offered the update.
#
# Usage: scripts/release-notes-floor.sh <ox-say-macos-*.tar.gz> <notes-file>
# Idempotent: an existing marker line is replaced. Fails (and leaves <notes-file> alone) when the
# package has no readable floor: the release then stays a draft, as for any failed check.
set -eu

pkg=${1:?usage: $0 <package.tar.gz> <notes-file>}
notes=${2:?usage: $0 <package.tar.gz> <notes-file>}
plist=ox-say/app/OxSayDictation.app/Contents/Info.plist

floor=$(tar -xzOf "$pkg" "$plist" | sed -n 's|.*<key>LSMinimumSystemVersion</key>[[:space:]]*<string>\([0-9][0-9.]*\)</string>.*|\1|p' | head -n 1)
case $floor in
    [0-9]*.[0-9]* | [0-9]*) : ;;
    *) echo "release-notes-floor: no LSMinimumSystemVersion in $plist of $pkg" >&2; exit 1 ;;
esac
case $floor in
    *[!0-9.]* | .* | *. | *..*) echo "release-notes-floor: unreadable floor [$floor]" >&2; exit 1 ;;
esac

tmp=$(mktemp "${TMPDIR:-/tmp}/notes-floor.XXXXXX")
trap 'rm -f "$tmp"' EXIT
# The old marker goes, and the blank lines before it with it, so a rerun does not stack them.
{ [ ! -f "$notes" ] || grep -v '^<!-- ox-say-min-macos: ' "$notes" || true; } |
    awk '/^[ \t]*$/ { blank = blank $0 "\n"; next } { printf "%s", blank; blank = ""; print }' >"$tmp"
printf '\n<!-- ox-say-min-macos: %s -->\n' "$floor" >>"$tmp"
cat "$tmp" >"$notes"
echo "release-notes-floor: macOS $floor"
