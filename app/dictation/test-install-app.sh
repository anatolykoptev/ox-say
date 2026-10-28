#!/usr/bin/env bash
# Tests for install-app.sh in a scratch directory. pkill, pgrep and open are
# stubbed, so no running app is stopped and nothing is launched.
#
#   bash app/dictation/test-install-app.sh
#
# Mutations that must turn this RED: in install-app.sh replace `clear_staging "$old"` by `clear_ours "$old"` - the
# partial .old scenario fails; make `partial_bundle` always succeed (`return 0` first) - the "real directory with other
# content" scenarios fail; delete the `for _ in 1 2 ... 10` wait loop - the "waits for the old copy to exit" scenario
# fails; drop the `[ ! -L "$1" ]` test from `clear_staging` - the symlinked staging scenarios fail; make `ours` skip the
# bundle identifier check (return success for any directory) in install-app.sh skip the
# bundle identifier check (return success for any directory) - the foreign
# bundle and the symlink scenarios fail; drop `clear_staging "$new"` - the
# leftover scenarios fail; drop the pkill - the running-copy scenario fails;
# drop the OX_SAY_APP_RELAUNCHES check in install-app.sh (always pkill and open)
# - the app-relaunches scenario fails.
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
run() { PATH="$tmp/stubs:$PATH" env -u OX_SAY_APP_RELAUNCHES bash "$here/install-app.sh" "$@" > "$tmp/out" 2>&1; }
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

# G: a partial staging copy from an interrupted run (no Info.plist) is cleared
mkdir -p "$tmp/g/.OxSayDictation.app.new/Contents/MacOS"
echo partial > "$tmp/g/.OxSayDictation.app.new/Contents/MacOS/OxSayDictation"
run "$tmp/src/OxSayDictation.app" "$tmp/g"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(marker "$tmp/g/OxSayDictation.app")" = new ] && [ ! -e "$tmp/g/.OxSayDictation.app.new" ]; then
    pass "a partial staging copy left by an interrupted run does not block the install"
else
    fail "partial staging: rc=$rc $(cat "$tmp/out")"
fi

# H: a foreign bundle under the staging name is refused, not merged into
bundle "$tmp/h/.OxSayDictation.app.new" com.example.other foreign
run "$tmp/src/OxSayDictation.app" "$tmp/h"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(marker "$tmp/h/.OxSayDictation.app.new")" = foreign ] && [ ! -e "$tmp/h/OxSayDictation.app" ]; then
    pass "a foreign bundle under the staging name is refused"
else
    fail "foreign staging: rc=$rc"
fi

# I: a running copy is stopped before the swap, and a failed start is not a failed install
printf '#!/bin/sh\necho "pkill $*" >> "%s/calls"\nexit 0\n' "$tmp" > "$tmp/stubs/pkill"
printf '#!/bin/sh\necho "open $*" >> "%s/calls"\nexit 1\n' "$tmp" > "$tmp/stubs/open"
: > "$tmp/calls"
run "$tmp/src/OxSayDictation.app" "$tmp/i"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^pkill -x OxSayDictation' "$tmp/calls" && [ "$(marker "$tmp/i/OxSayDictation.app")" = new ]; then
    pass "a running copy is stopped; a failed start still counts as installed"
else
    fail "running copy: rc=$rc calls=$(tr '\n' ';' < "$tmp/calls")"
fi

# J: started by the app (OX_SAY_APP_RELAUNCHES=1): the bundle is swapped, but the
# running copy is neither stopped nor is the new one opened - the app does both
# itself once no dictation runs.
bundle "$tmp/j/OxSayDictation.app" "$id" old
: > "$tmp/calls"
PATH="$tmp/stubs:$PATH" OX_SAY_APP_RELAUNCHES=1 bash "$here/install-app.sh" "$tmp/src/OxSayDictation.app" "$tmp/j" > "$tmp/out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(marker "$tmp/j/OxSayDictation.app")" = new ] &&
    [ ! -e "$tmp/j/.OxSayDictation.app.old" ] && [ ! -e "$tmp/j/.OxSayDictation.app.new" ] &&
    ! grep -q '^pkill ' "$tmp/calls" && ! grep -q '^open ' "$tmp/calls" &&
    grep -q 'relaunch itself' "$tmp/out"; then
    pass "an install the app started swaps the bundle and neither stops nor opens the app"
else
    fail "app relaunches: rc=$rc marker=$(marker "$tmp/j/OxSayDictation.app") calls=$(tr '\n' ';' < "$tmp/calls") out=$(cat "$tmp/out")"
fi

# K: without the variable (a terminal get.sh run) the old behaviour stands:
# stop the running copy, swap, open the new one.
bundle "$tmp/k/OxSayDictation.app" "$id" old
: > "$tmp/calls"
run "$tmp/src/OxSayDictation.app" "$tmp/k"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(marker "$tmp/k/OxSayDictation.app")" = new ] &&
    grep -q '^pkill -x OxSayDictation' "$tmp/calls" && grep -q '^open ' "$tmp/calls"; then
    pass "a terminal install stops the running copy and opens the new one"
else
    fail "terminal install: rc=$rc calls=$(tr '\n' ';' < "$tmp/calls")"
fi

# L: a value other than 1 does not count as the app's handoff.
bundle "$tmp/l/OxSayDictation.app" "$id" old
: > "$tmp/calls"
PATH="$tmp/stubs:$PATH" OX_SAY_APP_RELAUNCHES=0 bash "$here/install-app.sh" "$tmp/src/OxSayDictation.app" "$tmp/l" > "$tmp/out" 2>&1
if grep -q '^pkill ' "$tmp/calls" && grep -q '^open ' "$tmp/calls"; then
    pass "OX_SAY_APP_RELAUNCHES=0 keeps the terminal behaviour"
else
    fail "variable 0: calls=$(tr '\n' ';' < "$tmp/calls")"
fi

# M: a partial .old (a removal cut off after the swap: no Info.plist) does not block every later install
bundle "$tmp/m/OxSayDictation.app" "$id" old
mkdir -p "$tmp/m/.OxSayDictation.app.old/Contents/Resources"
echo half > "$tmp/m/.OxSayDictation.app.old/Contents/Resources/Old.icns"
run "$tmp/src/OxSayDictation.app" "$tmp/m"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(marker "$tmp/m/OxSayDictation.app")" = new ] && [ ! -e "$tmp/m/.OxSayDictation.app.old" ]; then
    pass "a partial .old left by a cut-off removal does not block the install"
else
    fail "partial .old: rc=$rc $(cat "$tmp/out"); $(ls -A "$tmp/m")"
fi

# N: a complete (ours) .new from an interrupted run is replaced, not merged into
bundle "$tmp/n/.OxSayDictation.app.new" "$id" stale
echo leftover > "$tmp/n/.OxSayDictation.app.new/Contents/MacOS/Extra"
run "$tmp/src/OxSayDictation.app" "$tmp/n"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(marker "$tmp/n/OxSayDictation.app")" = new ] && [ ! -e "$tmp/n/OxSayDictation.app/Contents/MacOS/Extra" ] &&
    [ ! -e "$tmp/n/.OxSayDictation.app.new" ]; then
    pass "a complete staging copy from an interrupted run is replaced whole"
else
    fail "complete staging: rc=$rc $(cat "$tmp/out")"
fi

# O: a symlink under a staging name is refused and its target is left alone (for both names)
for which in new old; do
    mkdir -p "$tmp/o-$which"
    bundle "$tmp/o-$which-target" "$id" target
    ln -s "$tmp/o-$which-target" "$tmp/o-$which/.OxSayDictation.app.$which"
    run "$tmp/src/OxSayDictation.app" "$tmp/o-$which"
    rc=$?
    if [ "$rc" -ne 0 ] && [ -L "$tmp/o-$which/.OxSayDictation.app.$which" ] && [ "$(marker "$tmp/o-$which-target")" = target ] &&
        [ ! -e "$tmp/o-$which/OxSayDictation.app" ]; then
        pass "a symlink under the .$which staging name is refused, its target untouched"
    else
        fail "symlink .$which: rc=$rc $(cat "$tmp/out")"
    fi
done

# P: a foreign bundle under the .old name is refused too
bundle "$tmp/p/.OxSayDictation.app.old" com.example.other foreign
run "$tmp/src/OxSayDictation.app" "$tmp/p"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(marker "$tmp/p/.OxSayDictation.app.old")" = foreign ] && [ ! -e "$tmp/p/OxSayDictation.app" ]; then
    pass "a foreign bundle under the .old name is refused"
else
    fail "foreign .old: rc=$rc"
fi

# Q: a real directory under a staging name that is not a bundle remnant (no Info.plist, but holds other files) is
# refused: the name alone does not make a directory ours to delete
for which in new old; do
    mkdir -p "$tmp/q-$which/.OxSayDictation.app.$which/Contents/MacOS"
    echo mine > "$tmp/q-$which/.OxSayDictation.app.$which/notes.txt"
    run "$tmp/src/OxSayDictation.app" "$tmp/q-$which"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(cat "$tmp/q-$which/.OxSayDictation.app.$which/notes.txt" 2>/dev/null)" = mine ]; then
        pass "a directory with other content under the .$which name is refused and kept"
    else
        fail "other content .$which: rc=$rc"
    fi
done

# R: a running copy that takes a moment to exit is waited for: pgrep reports it twice, then none, and the swap
# happens after that third look (not before the copy is gone)
printf '#!/bin/sh\necho "pkill $*" >> "%s/calls"\nexit 0\n' "$tmp" > "$tmp/stubs/pkill"
cat > "$tmp/stubs/pgrep" <<STUB
#!/bin/sh
echo "pgrep \$*" >> "$tmp/calls"
n=\$(grep -c '^pgrep ' "$tmp/calls")
[ "\$n" -le 2 ] && exit 0
exit 1
STUB
chmod +x "$tmp/stubs/pgrep"
printf '#!/bin/sh\necho "open $*" >> "%s/calls"\nexit 0\n' "$tmp" > "$tmp/stubs/open"
bundle "$tmp/r/OxSayDictation.app" "$id" old
: > "$tmp/calls"
run "$tmp/src/OxSayDictation.app" "$tmp/r"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^pgrep ' "$tmp/calls")" = 3 ] && [ "$(marker "$tmp/r/OxSayDictation.app")" = new ]; then
    pass "a running copy that is slow to exit is waited for (3 looks)"
else
    fail "waits for the old copy to exit: rc=$rc calls=$(tr '\n' ';' < "$tmp/calls")"
fi

# S: a copy that never exits does not hang the install: the wait is bounded (10 looks), the swap still happens
cat > "$tmp/stubs/pgrep" <<STUB
#!/bin/sh
echo "pgrep \$*" >> "$tmp/calls"
exit 0
STUB
bundle "$tmp/s/OxSayDictation.app" "$id" old
: > "$tmp/calls"
run "$tmp/src/OxSayDictation.app" "$tmp/s"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^pgrep ' "$tmp/calls")" = 10 ] && [ "$(marker "$tmp/s/OxSayDictation.app")" = new ]; then
    pass "a copy that never exits is waited for at most 10 looks, then replaced"
else
    fail "bounded wait: rc=$rc looks=$(grep -c '^pgrep ' "$tmp/calls")"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed" >&2
    exit 1
fi
