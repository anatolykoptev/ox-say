#!/bin/bash
# Tests for engine/lib-check.sh (check_static, check_patched) with fake lipo/otool on PATH,
# and for how engine/build.sh wires them. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-engine-checks.sh
#
# Mutations that must turn this RED:
#   * engine/lib-check.sh: drop the `|| { … }` after `libs=$(otool -L "$1")` — "otool fails" cases fail
#     (an empty list of libraries would pass)
#   * engine/lib-check.sh: make check_patched always `return 0` — "binary without the marker" fails
#   * engine/lib-check.sh: drop the empty-help test in check_help_flags — "empty --help" cases fail
#   * engine/build.sh: delete one `check_patched "$out/<engine>"` call — the wiring check for it fails
#   * engine/lib-check.sh: reword OXS_METALLIB_PATCH_MARKER — "patch file carries the marker" fails for all three
#   * engine/stt/ox-stt.cpp or engine/patches/qwentts/0002-*.patch: delete the 405's set_header("Allow", …) or drop a
#     method from it — "the 405 sets Allow to the accepted methods" fails
#   * engine/lib-check.sh: make write_pins_stamp copy the whole file (comments, other keys, pins of engines that were not
#     built) or write nothing — "the pins stamp holds the pins of the engines that were built" fails
#   * engine/build.sh: delete the `write_pins_stamp` call, or move it above the engine builds — "build.sh writes the pins
#     stamp last" fails; delete the `rm -f "$out/pins.env"` line — "build.sh drops a stale pins stamp first" fails
#   * engine/build.sh: delete the `git -C "$tts" config submodule.ggml.url "$GGML_REPO"` line, or move it below
#     `submodule update` — "build.sh repoints submodule.ggml.url at GGML_REPO before submodule update" fails
#   * engine/lib-check.sh: drop GGML from write_pins_stamp's tts-server prefixes — "the pins stamp holds the pins of
#     the engines that were built" fails (GGML_REPO= is missing from the stamp)
#   * engine/build.sh: drop `--cors-origins` from the check_help_flags "$out/ox-llm" line — "checks every flag the
#     daemon passes" fails (the flags are read from internal/daemon/meetings.go notesServerArgs)
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-checktest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got [$2], want [$3]"; fi; }

# shellcheck source=engine/lib-check.sh
. "$root/engine/lib-check.sh" 2>/dev/null || { fail "engine/lib-check.sh is missing or does not source"; echo "$fails check(s) failed" >&2; exit 1; }

mkdir "$tmp/bin"
# Fake lipo / otool: behaviour from $FAKE_LIPO ("arm64", "x86_64", "fail") and $FAKE_OTOOL ("clean", "rpath", "fail").
cat >"$tmp/bin/lipo" <<'FAKE'
#!/bin/bash
[ "$FAKE_LIPO" = fail ] && exit 1
echo "$FAKE_LIPO"
FAKE
cat >"$tmp/bin/otool" <<'FAKE'
#!/bin/bash
case $FAKE_OTOOL in
    fail) exit 1 ;;
    rpath) printf '%s:\n\t@rpath/libfoo.dylib (compatibility version 1.0.0)\n' "$2" ;;
    *) printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n' "$2" ;;
esac
FAKE
chmod +x "$tmp/bin/lipo" "$tmp/bin/otool"
PATH="$tmp/bin:$PATH"
arch=arm64

# static <name> <want rc> <lipo> <otool>, also run the way diar_build does: inside `if ( … )`, errexit suppressed.
static() {
    local name=$1 want=$2 rc=0
    FAKE_LIPO=$3 FAKE_OTOOL=$4 check_static /x/bin >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || rc=1
    check "check_static $name" "$rc" "$want"
    rc=0
    if (FAKE_LIPO=$3 FAKE_OTOOL=$4 check_static /x/bin >/dev/null 2>&1 && true); then rc=0; else rc=1; fi
    check "check_static $name (inside if ( … ))" "$rc" "$want"
}
static "clean thin arm64" 0 arm64 clean
static "wrong architecture" 1 x86_64 clean
static "@rpath dependency" 1 arm64 rpath
static "otool fails" 1 arm64 fail
static "lipo fails" 1 fail clean

# patched <name> <want rc> <file content>
printf 'junk\0%s\0junk' "%s: skipping '%s' - $OXS_METALLIB_PATCH_MARKER" >"$tmp/with"
printf 'junk\0%s\0junk' "%s: skipping '%s' - the metal library" >"$tmp/without"
rc=0; check_patched "$tmp/with" >/dev/null 2>&1 || rc=$?
check "check_patched: binary with the marker" "$rc" 0
rc=0; check_patched "$tmp/without" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || rc=1
check "check_patched: binary without the marker" "$rc" 1
rc=0; check_patched "$tmp/absent" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || rc=1
check "check_patched: unreadable file" "$rc" 1
rc=0; ( check_patched "$tmp/without" >/dev/null 2>&1 && true ) || rc=$?
[ "$rc" = 0 ] || rc=1
check "check_patched: binary without the marker, errexit suppressed" "$rc" 1

# check_help_flags <binary> <flag>...: the binary's --help names every flag the daemon passes it.
fakebin() { printf '#!/bin/bash\n%s\n' "$2" >"$tmp/$1"; chmod +x "$tmp/$1"; }
fakebin help-ok 'echo "  --host HOST   address"; echo "  --port N"'
fakebin help-lacks 'echo "  --port N"'
fakebin help-empty 'exit 0'
fakebin help-fails 'echo "  --host HOST --port N"; exit 3'
rc=0; check_help_flags "$tmp/help-ok" --host --port >/dev/null 2>&1 || rc=$?
check "check_help_flags: all flags present" "$rc" 0
rc=0; check_help_flags "$tmp/help-lacks" --host --port >"$tmp/o" 2>&1 || rc=$?
[ "$rc" = 0 ] || rc=1
check "check_help_flags: a flag is missing" "$rc" 1
check "check_help_flags: names the missing flag" "$(grep -c -- '--host' "$tmp/o")" 1
rc=0; check_help_flags "$tmp/help-empty" --host >"$tmp/o" 2>&1 || rc=$?
[ "$rc" = 0 ] || rc=1
check "check_help_flags: empty --help fails" "$rc" 1
check "check_help_flags: empty --help has its own message" "$(grep -c 'printed nothing' "$tmp/o")" 1
check "check_help_flags: empty --help does not blame a flag" "$(grep -c -- 'no longer has' "$tmp/o")" 0
# A nonzero --help exit (llama-server prints usage and may exit nonzero) does not matter, the text does.
rc=0; check_help_flags "$tmp/help-fails" --host --port >/dev/null 2>&1 || rc=$?
check "check_help_flags: nonzero exit with the text is fine" "$rc" 0
rc=0; check_help_flags "$tmp/absent" --host >"$tmp/o" 2>&1 || rc=$?
[ "$rc" = 0 ] || rc=1
check "check_help_flags: binary that cannot run fails" "$rc" 1

# engine/build.sh uses the library and runs the patch check on every engine it builds.
n=$(grep -cE '^\. "\$here/lib-check.sh"' "$root/engine/build.sh" || true)
check "build.sh sources lib-check.sh" "${n:-x}" 1
n=$(grep -cE '^check_static\(\)' "$root/engine/build.sh" || true)
check "build.sh does not define its own check_static" "${n:-x}" 0
n=$(grep -cE '^check_help_flags "\$out/ox-llm" .*--host' "$root/engine/build.sh" || true)
check "build.sh checks ox-llm's --help for --host" "${n:-x}" 1
for bin in tts-server ox-stt ox-align ox-llm audiocpp_server; do
    n=$(grep -cE "^[[:space:]]*check_patched \"\\\$(out|work)/$bin\"" "$root/engine/build.sh" || true)
    check "build.sh runs check_patched on $bin" "${n:-x}" 1
done

# The tts-server section must repoint submodule.ggml.url at the fork BEFORE `submodule update`:
# the pinned ggml commit is orphaned upstream and stays fetchable only through the fork's pin tag
# (#375), so an update that ran against .gitmodules' upstream URL could silently get nothing.
tts_sec=$(awk '/^# --- tts-server/,/^# --- ox-stt/' "$root/engine/build.sh")
url_ln=$(printf '%s\n' "$tts_sec" | grep -n '^[[:space:]]*git -C "\$tts" config submodule\.ggml\.url "\$GGML_REPO"' | head -1 | cut -d: -f1)
upd_ln=$(printf '%s\n' "$tts_sec" | grep -n '^[[:space:]]*git -C "\$tts" submodule update' | head -1 | cut -d: -f1)
rc=0; { [ -n "$url_ln" ] && [ -n "$upd_ln" ] && [ "$url_ln" -lt "$upd_ln" ]; } || rc=1
check "build.sh repoints submodule.ggml.url at GGML_REPO before submodule update" "$rc" 0

# write_pins_stamp: out/pins.env records the commits the binaries were built from, and only those lines: the repo
# urls and commits of the engines whose binary is in out/ (an engine a gate skipped leaves no pin), not comments or
# other assignments.
mkdir -p "$tmp/stamp-out"
: > "$tmp/stamp-out/tts-server"; : > "$tmp/stamp-out/ox-stt"; : > "$tmp/stamp-out/ox-diar"
printf '# a comment\nQWENTTS_REPO=https://example.invalid/q\nQWENTTS_COMMIT=aaa111\nGGML_COMMIT=ggg333\nGGML_REPO=https://example.invalid/g\nNOT_A_PIN=1\nWHISPER_COMMIT=bbb222\nAUDIOCPP_COMMIT=ccc444\nLLAMACPP_COMMIT=lll555\nDIAR_COMMIT=ddd666\n' > "$tmp/pins.env"
write_pins_stamp "$tmp/pins.env" "$tmp/stamp-out"
check "the pins stamp holds the pins of the engines that were built, repo and commit lines only" "$(tr '\n' ' ' < "$tmp/stamp-out/pins.env" 2>/dev/null)" "QWENTTS_REPO=https://example.invalid/q QWENTTS_COMMIT=aaa111 GGML_COMMIT=ggg333 GGML_REPO=https://example.invalid/g WHISPER_COMMIT=bbb222 DIAR_COMMIT=ddd666 "
rc=0; write_pins_stamp "$tmp/absent.env" "$tmp/stamp-out" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || rc=1
check "no pins.env to stamp from fails" "$rc" 1
mkdir -p "$tmp/empty-out"
rc=0; write_pins_stamp "$tmp/pins.env" "$tmp/empty-out" >/dev/null 2>&1 || rc=$?
check "no engine binary to stamp for fails" "$rc" 1
check "and writes no stamp" "$([ -e "$tmp/empty-out/pins.env" ] && echo yes || echo no)" no
# build.sh drops a stale stamp first (an interrupted build must not leave the previous build's pins next to new
# binaries) and writes the stamp as its last step, after the last engine.
n=$(grep -cE '^rm -f "\$out/pins.env"' "$root/engine/build.sh" || true)
check "build.sh drops a stale pins stamp first" "${n:-x}" 1
last=$(grep -nE '^(check_patched|write_pins_stamp|echo "built )|^[[:space:]]+(check_patched|echo "built )' "$root/engine/build.sh" | tail -1 | grep -c 'write_pins_stamp' || true)
check "build.sh writes the pins stamp last" "${last:-x}" 1

# The marker is a literal copied from the patches: the three patches that add the string must still carry it, or
# every engine build would fail at release time (and the unit test above only compares the constant with itself).
for patch in ggml/0003-metal-per-binary-metallib.patch audiocpp/0003-metal-per-binary-metallib.patch llamacpp/0001-metal-per-binary-metallib.patch; do
    f="$root/engine/patches/$patch"
    n=0
    [ -f "$f" ] && { n=$(grep -cF -- "$OXS_METALLIB_PATCH_MARKER" "$f" || true); }
    [ "${n:-0}" -ge 1 ] && n=1
    check "patch file carries the marker: $patch" "$n" 1
done

# Every long flag the daemon starts ox-llm with is in the --help check (read from the daemon, not a second list).
want=$(awk '/^func notesServerArgs/,/^}/' "$root/internal/daemon/meetings.go" | grep -o '"--[a-z0-9-]*"' | tr -d '"' | sort -u)
# Every `"--` literal must have been read as a plain flag: a `"--x=%d"` or a concatenated flag would drop out of the list.
fn=$(awk '/^func notesServerArgs/,/^}/' "$root/internal/daemon/meetings.go")
check "every -- literal of notesServerArgs is a plain flag" "$(printf '%s\n' "$fn" | grep -o '"--' | wc -l | tr -d ' ')" "$(printf '%s\n' "$want" | grep -c .)"
check "daemon's ox-llm flags were found" "$([ -n "$want" ] && echo yes || echo no)" yes
line=$(grep -E '^check_help_flags "\$out/ox-llm"' "$root/engine/build.sh" || true)
for flag in $want; do
    case " $line " in
        *" $flag "*) pass "build.sh checks ox-llm's --help for $flag" ;;
        *) fail "build.sh does not check ox-llm's --help for $flag (the daemon passes it)" ;;
    esac
done

# Every 405 names the methods the route accepts in Allow (RFC 9110 15.5.6, #65): the value must equal the list the
# guard in front of it compares against, read from the code, not a second copy. A tts-server patch line is a "+" line.
for f in engine/stt/ox-stt.cpp engine/patches/qwentts/0002-tts-server-local-only.patch; do
    guard=$(awk '/req\.method != "GET"/ {on=1} on {print} on && /\{[[:space:]]*$/ {exit}' "$root/$f")
    methods=$(printf '%s\n' "$guard" | grep -o 'method != "[A-Z]*"' | grep -o '"[A-Z]*"' | tr -d '"' | paste -sd, - | sed 's/,/, /g')
    allow=$(grep -o 'set_header("Allow", "[^"]*")' "$root/$f" | sed 's/.*"Allow", "//; s/")$//')
    check "$f: the guard's methods were found" "$([ -n "$methods" ] && echo yes || echo no)" yes
    check "$f: the 405 sets Allow to the accepted methods" "$allow" "$methods"
done

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
