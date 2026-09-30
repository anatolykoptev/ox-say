#!/usr/bin/env bash
# Tests for install-app.sh in a scratch directory. pkill, pgrep and open are
# stubbed, so no running app is stopped and nothing is launched.
#
#   bash app/dictation/test-install-app.sh
#
# Mutation that must turn this RED: make `ours` in install-app.sh skip the
# bundle identifier check (return success for any directory) - the foreign
# bundle and the symlink scenarios fail.
set -u

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-apptest.XXXXXX")
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT
fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$tmp/stubs"
# pkill and pgrep find no running copy (exit 1); open succeeds.
for spec in pkill:1 pgrep:1 open:0; do
    tool=${spec%%:*}
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit %s\n' "$tool" "$tmp" "${spec#*:}" > "$tmp/stubs/$tool"
    chmod +x "$tmp/stubs/$tool"
done

# bundle <path> <bundle id> <marker>: a minimal app bundle.
bundle() {
    mkdir -p "$1/Contents/MacOS"
    plutil -create xml1 "$1/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
    echo "$3" > "$1/Contents/MacOS/OxSayDictation"
}
run() { PATH="$tmp/stubs:$PATH" bash "$here/install-app.sh" "$@" > "$tmp/out" 2>&1; }
marker() { cat "$1/Contents/MacOS/OxSayDictation" 2>/dev/null || echo none; }

id=io.github.anatolykoptev.ox-say.dictation
bundle "$tmp/src/OxSayDictation.app" "$id" new

# A: fresh install
run "$tmp/src/OxSayDictation.app" "$tmp/a"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(marker "$tmp/a/OxSayDictation.app")" = new ] && grep -q '^open ' "$tmp/calls"; then
    pass "fresh install copies the bundle and starts it"
else
    fail "fresh install: $(cat "$tmp/out")"
fi

# B: replacing our own older copy, with an extra file the new version dropped
bundle "$tmp/b/OxSayDictation.app" "$id" old
mkdir -p "$tmp/b/OxSayDictation.app/Contents/Resources"
echo x > "$tmp/b/OxSayDictation.app/Contents/Resources/Old.icns"
run "$tmp/src/OxSayDictation.app" "$tmp/b"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(marker "$tmp/b/OxSayDictation.app")" = new ] && [ ! -e "$tmp/b/OxSayDictation.app/Contents/Resources" ] &&
    [ ! -e "$tmp/b/.OxSayDictation.app.old" ] && [ ! -e "$tmp/b/.OxSayDictation.app.new" ]; then
    pass "an older copy of ours is replaced whole, no staging left"
else
    fail "replace ours: $(cat "$tmp/out"); $(ls -A "$tmp/b")"
fi

# C: a foreign bundle at the destination is left alone
bundle "$tmp/c/OxSayDictation.app" com.example.other foreign
run "$tmp/src/OxSayDictation.app" "$tmp/c"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(marker "$tmp/c/OxSayDictation.app")" = foreign ]; then
    pass "a foreign bundle is refused and untouched"
else
    fail "foreign bundle: rc=$rc marker=$(marker "$tmp/c/OxSayDictation.app")"
fi

# D: a symlink at the destination is refused, its target untouched
bundle "$tmp/d-target/OxSayDictation.app" "$id" target
mkdir -p "$tmp/d"
ln -s "$tmp/d-target/OxSayDictation.app" "$tmp/d/OxSayDictation.app"
run "$tmp/src/OxSayDictation.app" "$tmp/d"
rc=$?
if [ "$rc" -ne 0 ] && [ -L "$tmp/d/OxSayDictation.app" ] && [ "$(marker "$tmp/d-target/OxSayDictation.app")" = target ]; then
    pass "a symlinked destination is refused"
else
    fail "symlink: rc=$rc"
fi

# E: --check answers without changing anything
run --check "$tmp/c"
rc_foreign=$?
run --check "$tmp/b"
rc_ours=$?
if [ "$rc_foreign" -ne 0 ] && [ "$rc_ours" -eq 0 ]; then
    pass "--check refuses a foreign bundle and accepts ours"
else
    fail "--check: foreign=$rc_foreign ours=$rc_ours"
fi

# F: a source that is not our bundle is refused before anything is touched
bundle "$tmp/bad/OxSayDictation.app" com.example.other bad
run "$tmp/bad/OxSayDictation.app" "$tmp/b"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(marker "$tmp/b/OxSayDictation.app")" = new ]; then
    pass "a foreign source bundle is refused"
else
    fail "foreign source: rc=$rc"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed" >&2
    exit 1
fi
