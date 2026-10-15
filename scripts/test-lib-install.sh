#!/bin/bash
# Sandbox tests for scripts/lib-install.sh. Every scenario runs in a child
# bash with HOME pointed at a scratch dir: no launchctl, nothing outside the
# sandbox is touched. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-lib-install.sh
#
# Mutations that must turn this RED:
#   * restore the render loop in lib-install.sh that writes every OX_SAY_*
#     variable (drop the oxs_daemon_var filter) — scenario A fails
#   * write the render call in scenario-installer.sh back as
#     tmp=$(oxs_render_agent …) — the broken-template scenario fails:
#     bash clears `set -e` inside $(…) so the install step gets reached
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
label=io.github.anatolykoptev.ox-say
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-libtest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got [$2], want [$3]"; fi; }
check_in_log() { if grep -qF "$3" "$2"; then pass "$1"; else fail "$1 — missing [$3] in log"; fi; }

# The allowlist the installer hands to lib-install.sh. Prefer the real
# binary's `env-keys` output so the lib↔binary seam is exercised too; fall
# back to a fixed list when go is unavailable (the table↔loader consistency
# itself is covered by the Go tests).
if command -v go >/dev/null 2>&1; then
    (cd "$root" && go build -o "$tmp/ox-say" ./cmd/ox-say)
    bin=$tmp/ox-say
    keysfile=
else
    bin=
    keysfile=$tmp/env-keys
    printf '%s\n' OX_SAY_ADDR OX_SAY_CACHE_DIR OX_SAY_HOME OX_SAY_STT_GPU >"$keysfile"
fi

# One install scenario: read settings, render the agent, copy the result to
# $OXS_TMP/render.plist and record the post-settings environment.
cat >"$tmp/scenario-render.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export HOME=$OXS_HOME
. "$OXS_ROOT/scripts/lib-install.sh"
if [ -n "${OXS_BIN:-}" ]; then
    oxs_env_keys_from "$OXS_BIN"
else
    oxs_env_keys=$(cat "$OXS_KEYS")
fi
oxs_settings
compgen -e | grep '^OX_SAY_' >"$OXS_TMP/env-after-settings.txt" 2>/dev/null || true
rd=$(mktemp -d "$OXS_TMP/rd.XXXXXX")
oxs_render_agent "$OXS_TEMPLATE" "$rd/agent.plist"
cp "$rd/agent.plist" "$OXS_TMP/render.plist"
EOF

# The caller-shaped render: caller owns mktemp + trap, then calls the render
# as a PLAIN statement so `set -e` fires on a failing plutil. The final echo
# stands in for the install step (engine swap, agent reload). Mutation that
# must go RED: write the call back as tmp=$(oxs_render_agent …) — bash clears
# `set -e` inside $(…) so the install step gets reached on a broken render.
cat >"$tmp/scenario-installer.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export HOME=$OXS_HOME
. "$OXS_ROOT/scripts/lib-install.sh"
if [ -n "${OXS_BIN:-}" ]; then
    oxs_env_keys_from "$OXS_BIN"
else
    oxs_env_keys=$(cat "$OXS_KEYS")
fi
oxs_settings
tmpdir=$(mktemp -d "$OXS_TMP/it.XXXXXX")
tmp="$tmpdir/agent.plist"
trap 'rm -f "$tmp"; rmdir "$tmpdir" 2>/dev/null || true' EXIT
oxs_render_agent "$OXS_TEMPLATE" "$tmp"
echo reached >"$OXS_TMP/installed"
EOF

# oxs_settings must refuse to run before the env-key list is known: an empty
# allowlist would silently drop every carried-over setting.
cat >"$tmp/scenario-nokeys.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export HOME=$OXS_HOME
. "$OXS_ROOT/scripts/lib-install.sh"
oxs_settings
echo reached >"$OXS_TMP/installed"
EOF

plist_keys() {
    plutil -extract EnvironmentVariables xml1 -o - "$1" 2>/dev/null |
        sed -n 's|.*<key>\([^<]*\)</key>.*|\1|p' | LC_ALL=C sort
}
plist_val() { plutil -extract "EnvironmentVariables.$2" raw -o - "$1" 2>/dev/null || true; }

# scenario <name> <script> [env assignments…] — runs the child with a scrubbed
# environment (env -i), captures its log at $tmp/<name>.log
scenario() {
    local name=$1 script=$2
    shift 2
    env -i PATH="$PATH" OXS_ROOT="$root" OXS_TMP="$tmp" \
        OXS_BIN="$bin" OXS_KEYS="$keysfile" \
        OXS_HOME="$tmp/home-$name" OXS_TEMPLATE="$tmp/template-$name.plist" \
        "$@" bash "$tmp/$script" >"$tmp/$name.log" 2>&1
}

for s in render carry stale nokeys; do
    cp "$root/launchd/$label.plist.in" "$tmp/template-$s.plist"
done
# A template that makes a mid-render plutil fail while the file still lints
# clean: EnvironmentVariables is a string, so replacing a key under it errors.
cat >"$tmp/template-broken.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>ProgramArguments</key><array><string>x</string></array>
<key>EnvironmentVariables</key><string>not-a-dict</string>
<key>StandardOutPath</key><string>/tmp/o</string>
<key>StandardErrorPath</key><string>/tmp/e</string>
</dict></plist>
EOF

# --- A: the render writes only variables the daemon reads -------------------
scenario render scenario-render.sh \
    OX_SAY_NO_SELFTEST=1 OX_SAY_NO_MCP=1 OX_SAY_GET_URL=x OX_SAY_ADDR=127.0.0.1:9999 \
    || fail "render scenario failed: $(tail -3 "$tmp/render.log")"
if [ -f "$tmp/render.plist" ]; then
    check "render writes only daemon vars" "$(plist_keys "$tmp/render.plist")" "OX_SAY_ADDR
PATH"
    check "OX_SAY_ADDR value" "$(plist_val "$tmp/render.plist" OX_SAY_ADDR)" "127.0.0.1:9999"
    # Without it launchd throttles the daemon and its STT child (priority 20,
    # not an app's 31), and dictation stalls on a busy Mac. Mutation: drop
    # ProcessType from the template -> RED.
    check "agent runs as Interactive" \
        "$(plutil -extract ProcessType raw -o - "$tmp/render.plist" 2>/dev/null || true)" "Interactive"
fi

# --- B: carry-over from an installed agent ----------------------------------
# Install A's plist as the existing agent, then re-run with nothing set.
mkdir -p "$tmp/home-carry/Library/LaunchAgents"
cp "$tmp/render.plist" "$tmp/home-carry/Library/LaunchAgents/$label.plist"
scenario carry scenario-render.sh \
    || fail "carry scenario failed: $(tail -3 "$tmp/carry.log")"
if [ -f "$tmp/render.plist" ]; then
    check "carry-over keeps only OX_SAY_ADDR" "$(plist_keys "$tmp/render.plist")" "OX_SAY_ADDR
PATH"
    check "carried value" "$(plist_val "$tmp/render.plist" OX_SAY_ADDR)" "127.0.0.1:9999"
fi
check_in_log "carry-over announced" "$tmp/carry.log" "keeping OX_SAY_ADDR"

# --- C: a stale installer knob in the installed plist is dropped ------------
# Seed the installed agent with OX_SAY_GET_URL (the live plist carries it —
# the denylist forgot it). It must not be exported, nor reach the next render.
mkdir -p "$tmp/home-stale/Library/LaunchAgents"
cp "$root/launchd/$label.plist.in" "$tmp/home-stale/Library/LaunchAgents/$label.plist"
plutil -replace EnvironmentVariables.OX_SAY_GET_URL -string http://stale \
    "$tmp/home-stale/Library/LaunchAgents/$label.plist"
plutil -replace EnvironmentVariables.OX_SAY_ADDR -string 127.0.0.1:9999 \
    "$tmp/home-stale/Library/LaunchAgents/$label.plist"
scenario stale scenario-render.sh \
    || fail "stale scenario failed: $(tail -3 "$tmp/stale.log")"
if [ -f "$tmp/render.plist" ]; then
    check "stale GET_URL gone from render" "$(plist_keys "$tmp/render.plist")" "OX_SAY_ADDR
PATH"
fi
if grep -qx 'OX_SAY_GET_URL' "$tmp/env-after-settings.txt" 2>/dev/null; then
    fail "OX_SAY_GET_URL exported into the environment"
else
    pass "OX_SAY_GET_URL not exported"
fi
check_in_log "drop announced" "$tmp/stale.log" "dropping OX_SAY_GET_URL"

# --- D: a failing render stops the installer before the install step --------
rm -f "$tmp/installed"
scenario broken scenario-installer.sh OX_SAY_ADDR=127.0.0.1:9999
rc=$?
if [ $rc -ne 0 ] && [ ! -f "$tmp/installed" ]; then
    pass "broken template: set -e stopped the run before the install step"
else
    fail "broken template: rc=$rc installed=$([ -f "$tmp/installed" ] && echo yes || echo no)"
fi

# --- E: no env-key list -> refuse (fail closed) ------------------------------
rm -f "$tmp/installed"
scenario nokeys scenario-nokeys.sh
rc=$?
if [ $rc -ne 0 ] && [ ! -f "$tmp/installed" ]; then
    pass "oxs_settings refuses before oxs_env_keys_from"
else
    fail "nokeys: rc=$rc installed=$([ -f "$tmp/installed" ] && echo yes || echo no)"
fi
check_in_log "refusal names the fix" "$tmp/nokeys.log" "oxs_env_keys_from"

# --- F: the real installers call the render as a plain statement -----------
# Scenario D proves the shape on a copy; this pins the real call sites to it.
for f in install.sh install-release.sh; do
    n=$(grep -cE '^[^#]*[$][(]oxs_render_agent' "$root/scripts/$f" || true) # code, not comments
    check "$f renders without \$(…), so errexit applies" "${n:-x}" 0
done

# --- G: the self-test accepts the phrase, not any text containing "ready" ---
# The 2026-10-14 old-Mac install passed with a 15 s hallucination because
# its tail contained "ready". Mutation: restore `*ready*) ok=1` in
# install-release.sh — the call-site pin below fails.
selftest_ok() { ( . "$root/scripts/lib-install.sh" && oxs_selftest_heard_ok "$1" "ox-say is ready" ); }
halluc="Her face was stretched into distortion, a drop of blood trickled slowly down her taut neck, and the door was ready to open when the water came."
for heard in "Oxay is ready." "OX say is ready" "ox-say is ready" "Ox, say, is ready!" "Okse is ready, and the"; do
    if selftest_ok "$heard"; then pass "self-test accepts [$heard]"; else fail "self-test rejected [$heard]"; fi
done
for heard in "$halluc" "" "ox-say is steady" "ox say is not ready at all really" "Okse is ready, and the sky"; do
    if selftest_ok "$heard"; then fail "self-test accepted [$heard]"; else pass "self-test rejects [${heard:0:30}]"; fi
done
n=$(grep -cE '^[^#]*[*]ready[*]' "$root/scripts/install-release.sh" || true)
check "install-release.sh has no *ready* substring pass" "${n:-x}" 0
n=$(grep -cE '^[^#]*oxs_selftest_heard_ok' "$root/scripts/install-release.sh" || true)
check "install-release.sh calls oxs_selftest_heard_ok" "${n:-x}" 1

# --- H: VoxCPM2 is opt-in, Apple Silicon with >= 24 GB only -----------------
# A stub fetch records its argv; stub uname and sysctl on PATH play the host.
# Mutation (lib-install.sh oxs_fetch_models): drop the oxs_voxcpm2_ok call ->
# the x86_64, 16 GB and 23.99 GB cases fail. Mutation: `-lt` -> `-le` in
# oxs_voxcpm2_ok -> the exactly-24 GB case fails.
vox_case() { # name arch memsize want [extra env assignments...]
    local d="$tmp/vox-$1" name=$1 arch=$2 mem=$3 want=$4
    shift 4
    mkdir -p "$d/bin"
    printf '#!/bin/sh\necho "$@" > "%s/fetch-args"\n' "$d" > "$d/fetch"
    printf '#!/bin/sh\necho %s\n' "$arch" > "$d/bin/uname"
    printf '#!/bin/sh\necho %s\n' "$mem" > "$d/bin/sysctl"
    chmod +x "$d/fetch" "$d/bin/uname" "$d/bin/sysctl"
    env PATH="$d/bin:$PATH" OX_SAY_WITH_VOXCPM2=1 "$@" \
        bash -c ". '$root/scripts/lib-install.sh'; oxs_fetch_models '$d/fetch'" >"$d/log" 2>&1
    check "voxcpm2 opt-in $name" "$(cat "$d/fetch-args")" "$want"
}
vox_case arm64-32g arm64 34359738368 "--with-voxcpm2"
vox_case arm64-24g-exact arm64 25769803776 "--with-voxcpm2"
vox_case arm64-just-under-24g arm64 25769803775 ""
vox_case arm64-16g arm64 17179869184 ""
vox_case x86_64 x86_64 34359738368 ""
vox_case with-whisper arm64 34359738368 "--with-whisper --with-voxcpm2" OX_SAY_WITH_WHISPER=1
check_in_log "x86_64 refusal says why" "$tmp/vox-x86_64/log" "Apple Silicon only"
check_in_log "16 GB refusal says why" "$tmp/vox-arm64-16g/log" "needs 24 GB"
# Not requested -> never asked for, whatever the host.
d="$tmp/vox-unset"
mkdir -p "$d"
printf '#!/bin/sh\necho "$@" > "%s/fetch-args"\n' "$d" > "$d/fetch"
chmod +x "$d/fetch"
env -u OX_SAY_WITH_VOXCPM2 bash -c ". '$root/scripts/lib-install.sh'; oxs_fetch_models '$d/fetch'" >/dev/null 2>&1
check "voxcpm2 not requested" "$(cat "$d/fetch-args")" ""

# --- I: audiocpp_server is an optional engine --------------------------------
# The arm64 package carries it, the x86_64 one does not. Mutation: drop the
# optional block in oxs_install_engines -> the binary is missing -> RED.
engine_case() { # name with-audiocpp
    local d="$tmp/eng-$1" bin
    mkdir -p "$d/out/licenses" "$d/home"
    echo x > "$d/out/licenses/x.LICENSE"
    for bin in tts-server ox-stt ox-align $( [ "$2" = yes ] && echo audiocpp_server ); do
        printf '#!/bin/sh\n' > "$d/out/$bin"
        chmod +x "$d/out/$bin"
    done
    bash -c "set -euo pipefail; . '$root/scripts/lib-install.sh'; home='$d/home'; oxs_install_engines '$d/out'" >"$d/log" 2>&1
    echo "rc=$?" >> "$d/log"
    for f in "$d/home/engine"/*; do
        if [ -f "$f" ]; then
            printf '%s ' "$(basename "$f")"
        fi
    done
}
check "engines with audiocpp_server" "$(engine_case with yes)" "audiocpp_server ox-align ox-stt tts-server "
check_in_log "with audiocpp: exit 0" "$tmp/eng-with/log" "rc=0"
check "engines without audiocpp_server" "$(engine_case without no)" "ox-align ox-stt tts-server "
check_in_log "without audiocpp: exit 0" "$tmp/eng-without/log" "rc=0"

# --- J: audio.cpp is built only on request ---------------------------------
# A source install (scripts/install.sh -> engine/build.sh) must not clone and
# build a second engine nobody asked for. Mutation (engine/want-audiocpp.sh:9):
# drop the `&& { ...DIST... || ...WITH_VOXCPM2... }` clause so arm64 always
# builds -> "audiocpp not built on plain arm64" fails.
want_case() { # name arch want [env assignments...]
    local name=$1 arch=$2 want=$3 got=no
    shift 3
    if env -i PATH="$PATH" "$@" bash -c ". '$root/engine/want-audiocpp.sh'; want_audiocpp '$arch'"; then got=yes; fi
    check "audiocpp built: $name" "$got" "$want"
}
want_case "plain arm64" arm64 no
want_case "arm64 dist" arm64 yes OX_SAY_DIST=1
want_case "arm64 with-voxcpm2" arm64 yes OX_SAY_WITH_VOXCPM2=1
want_case "arm64 dist=0" arm64 no OX_SAY_DIST=0 OX_SAY_WITH_VOXCPM2=0
want_case "x86_64 dist" x86_64 no OX_SAY_DIST=1
want_case "x86_64 with-voxcpm2" x86_64 no OX_SAY_WITH_VOXCPM2=1
# build.sh really goes through the predicate (not a copy of it).
n=$(grep -cE '^[^#]*want_audiocpp "[$]arch"' "$root/engine/build.sh" || true)
check "build.sh calls want_audiocpp" "${n:-x}" 1

echo
if [ "$fails" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed" >&2
    exit 1
fi
