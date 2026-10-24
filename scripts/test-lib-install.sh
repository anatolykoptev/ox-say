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
    printf '%s\n' OX_SAY_ADDR OX_SAY_CACHE_DIR OX_SAY_HOME OX_SAY_STT_GPU OX_SAY_TTS_MODEL OX_SAY_STT_MODEL >"$keysfile"
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

for s in render carry stale nokeys ttsmodel relmodel; do
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

# --- M: a model NAME is not a path; a weights path still must be absolute ----
# Mutation: restore the old glob (drop the OX_SAY_TTS_MODEL case in
# oxs_settings) -> the "TTS model name accepted" case fails.
rm -f "$tmp/render.plist"
if scenario ttsmodel scenario-render.sh OX_SAY_NO_SELFTEST=1 OX_SAY_TTS_MODEL=voxcpm2; then
    check "TTS model name accepted, written to the agent" "$(plist_val "$tmp/render.plist" OX_SAY_TTS_MODEL)" "voxcpm2"
else
    fail "TTS model name accepted — installer refused it: $(tail -2 "$tmp/ttsmodel.log")"
fi
if scenario relmodel scenario-render.sh OX_SAY_NO_SELFTEST=1 OX_SAY_STT_MODEL=models/x.bin; then
    fail "relative path key refused — installer accepted OX_SAY_STT_MODEL=models/x.bin"
else
    check_in_log "relative path key refused, named" "$tmp/relmodel.log" "OX_SAY_STT_MODEL must be an absolute path"
fi

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
# oxs_voxcpm2_ok -> the exactly-24 GB case fails. Mutation: delete the
# `case $mem` digits check in oxs_voxcpm2_ok -> the sysctl-fails, sysctl-empty
# and sysctl-garbage cases fail (they used to fetch 3 GB).
vox_case() { # name arch memsize want [extra env assignments...]
    local d="$tmp/vox-$1" name=$1 arch=$2 mem=$3 want=$4
    shift 4
    mkdir -p "$d/bin"
    printf '#!/bin/sh\necho "$@" > "%s/fetch-args"\n' "$d" > "$d/fetch"
    printf '#!/bin/sh\necho %s\n' "$arch" > "$d/bin/uname"
    case $mem in
        fail) printf '#!/bin/sh\nexit 1\n' > "$d/bin/sysctl" ;;
        *) printf '#!/bin/sh\necho %s\n' "$mem" > "$d/bin/sysctl" ;;
    esac
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
vox_case sysctl-fails arm64 fail ""
vox_case sysctl-empty arm64 "" ""
vox_case sysctl-garbage arm64 "n/a" ""
vox_case with-whisper arm64 34359738368 "--with-whisper --with-voxcpm2" OX_SAY_WITH_WHISPER=1
check_in_log "x86_64 refusal says why" "$tmp/vox-x86_64/log" "Apple Silicon only"
check_in_log "unreadable memory refusal says why (sysctl fails)" "$tmp/vox-sysctl-fails/log" "cannot read this Mac's memory size"
check_in_log "unreadable memory refusal says why (empty)" "$tmp/vox-sysctl-empty/log" "cannot read this Mac's memory size"
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
    for bin in tts-server ox-stt ox-align ox-llm $( [ "$2" = yes ] && echo audiocpp_server ); do
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
check "engines with audiocpp_server" "$(engine_case with yes)" "audiocpp_server ox-align ox-llm ox-stt tts-server "
check_in_log "with audiocpp: exit 0" "$tmp/eng-with/log" "rc=0"
check "engines without audiocpp_server" "$(engine_case without no)" "ox-align ox-llm ox-stt tts-server "
check_in_log "without audiocpp: exit 0" "$tmp/eng-without/log" "rc=0"

# --- I2: ox-diar is installed when the package carries it ----------------------
# Mutation: drop the `if [ -x "$out/ox-diar" ]` block in oxs_install_engines -> the binary is missing -> RED.
diar_case() { # name with-diar
    local d="$tmp/diar-$1" bin
    mkdir -p "$d/out/licenses" "$d/home"
    echo x > "$d/out/licenses/x.LICENSE"
    for bin in tts-server ox-stt ox-align ox-llm $( [ "$2" = yes ] && echo ox-diar ); do
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
check "ox-diar installed with the other engines" "$(diar_case with yes)" "ox-align ox-diar ox-llm ox-stt tts-server "
check_in_log "with ox-diar: exit 0" "$tmp/diar-with/log" "rc=0"
check "a package without ox-diar still installs" "$(diar_case without no)" "ox-align ox-llm ox-stt tts-server "
check_in_log "without ox-diar: exit 0" "$tmp/diar-without/log" "rc=0"

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
# The gate: not wanted -> a stale binary in out/ is removed and the build stops;
# wanted -> it is left alone and the build goes on. Mutations
# (engine/want-audiocpp.sh, audiocpp_gate): drop `rm -f "$2/audiocpp_server"`
# -> "stale audiocpp_server plain arm64" fails; `return 1` -> `return 0` ->
# "gate continues the build: plain arm64" fails.
gate_case() { # name arch want-continue want-stale-left [env assignments...]
    local name=$1 arch=$2 cont=$3 left=$4 d="$tmp/gate-$1" rc=stop stale=gone stalelib=gone
    shift 4
    mkdir -p "$d"
    : > "$d/audiocpp_server"
    : > "$d/audiocpp_server.metallib"
    : > "$d/audiocpp_server-tensor.metallib"
    if env -i PATH="$PATH" "$@" bash -c ". '$root/engine/want-audiocpp.sh'; audiocpp_gate '$arch' '$d'"; then rc=go; fi
    if [ -e "$d/audiocpp_server" ]; then stale=left; fi
    if [ -e "$d/audiocpp_server.metallib" ] || [ -e "$d/audiocpp_server-tensor.metallib" ]; then stalelib=left; fi
    check "gate continues the build: $name" "$rc" "$cont"
    check "stale audiocpp_server $name" "$stale" "$left"
    check "stale audiocpp_server metallibs $name" "$stalelib" "$left"
}
gate_case "plain arm64" arm64 stop gone
gate_case "x86_64 dist" x86_64 stop gone OX_SAY_DIST=1
gate_case "arm64 dist" arm64 go left OX_SAY_DIST=1
gate_case "arm64 with-voxcpm2" arm64 go left OX_SAY_WITH_VOXCPM2=1
# The call sites cannot run without a real build, so they are pinned by shape;
# the release.yml arm64 `test -x engine/audiocpp_server` is the behavioural check.
n=$(grep -cE '^[^#]*if audiocpp_gate "[$]arch" "[$]out"; then' "$root/engine/build.sh" || true)
check "build.sh guards the audio.cpp block with audiocpp_gate" "${n:-x}" 1
n=$(grep -cE '^[^#]*OX_SAY_DIST=1 "[$]root/engine/build.sh"' "$root/scripts/package-release.sh" || true)
check "package-release.sh builds with OX_SAY_DIST=1" "${n:-x}" 1

# --- J2: ox-diar is built only where it can run -----------------------------
# A source install on macOS 13/14 or with Xcode 16 must not fail on a Swift 6.2 package it cannot use. The tool
# versions are stubs on PATH. Mutations (engine/want-diar.sh): drop the `[ "${OX_SAY_DIST:-0}" = 1 ] ||` term ->
# "ox-diar built: dist on macOS 14" fails; change `-ge 15` to `-ge 14` -> "macOS 14, Swift 6.3" fails; change
# `[ "$swift_minor" -ge 2 ]` to `-ge 1` -> "macOS 15, Swift 6.1" fails; (build.sh) change `if diar_gate "$out"; then` to
# `if true; then` -> the call-site check fails.
diar_stubs="$tmp/diar-stubs"
mkdir -p "$diar_stubs"
want_diar_case() { # name macOS swift-version want [env assignments...]
    local name=$1 os=$2 sw=$3 want=$4 got=no d="$tmp/wd-$1"
    shift 4
    mkdir -p "$d"
    printf '#!/bin/sh\necho %s\n' "$os" > "$d/sw_vers"
    printf '#!/bin/sh\necho "Apple Swift version %s (swiftlang-6000.0.1)"\n' "$sw" > "$d/swift"
    chmod +x "$d/sw_vers" "$d/swift"
    if env -i PATH="$d:/usr/bin:/bin" "$@" bash -c ". '$root/engine/want-diar.sh'; want_diar"; then got=yes; fi
    check "ox-diar built: $name" "$got" "$want"
}
want_diar_case "macOS 14, Swift 6.3" 14.8 6.3.3 no
want_diar_case "macOS 15, Swift 6.1" 15.7 6.1.2 no
want_diar_case "macOS 15, Swift 6.2" 15.7 6.2 yes
want_diar_case "macOS 26, Swift 6.3" 26.5.1 6.3.3 yes
want_diar_case "no usable swift" 26.5.1 garbage no
want_diar_case "dist on macOS 14" 14.8 5.10 yes OX_SAY_DIST=1
want_diar_case "with-diar on macOS 13" 13.6 5.10 yes OX_SAY_WITH_DIAR=1
want_diar_case "dist=0 with-diar=0" 14.8 5.10 no OX_SAY_DIST=0 OX_SAY_WITH_DIAR=0
gate_diar_case() { # name macOS swift want-continue want-stale-left [env assignments...]
    local name=$1 os=$2 sw=$3 cont=$4 left=$5 d="$tmp/gd-$1" rc=stop stale=gone
    shift 5
    mkdir -p "$d/out"
    : > "$d/out/ox-diar"
    printf '#!/bin/sh\necho %s\n' "$os" > "$d/sw_vers"
    printf '#!/bin/sh\necho "Apple Swift version %s (swiftlang-6000.0.1)"\n' "$sw" > "$d/swift"
    chmod +x "$d/sw_vers" "$d/swift"
    if env -i PATH="$d:/usr/bin:/bin" "$@" bash -c ". '$root/engine/want-diar.sh'; diar_gate '$d/out'" 2>"$d/err"; then rc=go; fi
    if [ -e "$d/out/ox-diar" ]; then stale=left; fi
    check "diar gate continues the build: $name" "$rc" "$cont"
    check "stale ox-diar $name" "$stale" "$left"
    if [ "$cont" = stop ]; then check_in_log "diar gate says why: $name" "$d/err" "ox-diar (speaker diarization) not built"; fi
}
gate_diar_case "macOS 14" 14.8 6.3.3 stop gone
gate_diar_case "macOS 15, Swift 6.3" 15.7 6.3.3 go left
gate_diar_case "dist on macOS 14" 14.8 5.10 go left OX_SAY_DIST=1
n=$(grep -cE '^[^#]*diar_gate "[$]out"' "$root/engine/build.sh" || true)
check "build.sh guards the ox-diar block with diar_gate" "${n:-x}" 1
n=$(grep -cE '^[^#]*diar_build "[$]here" "[$]work" "[$]out"' "$root/engine/build.sh" || true)
check "build.sh builds ox-diar through diar_build" "${n:-x}" 1
n=$(grep -cE '^[^#]*"[$]arch" != arm64' "$root/engine/build.sh" || true)
check "build.sh builds ox-diar on Apple Silicon only (the Intel smoke failed)" "${n:-x}" 1

# --- J3: which mode opened the gate, and what a failing build does -------------
# An automatic gate (macOS 15+ with Swift 6.2+, nobody asked) must never turn a source install that worked yesterday
# into a failed one: its build failure drops the binary, warns once and goes on. A requested or release build
# stays fatal. Mutations (engine/want-diar.sh): in diar_build change `[ "${DIAR_MODE:-}" = auto ]` to `false` -> the
# automatic cases fail; in diar_mode swap the `dist` and `requested` branches' echo -> the mode cases fail; (build.sh)
# call diar_build without the `diar_gate` result being used -> the call-site checks above fail.
diar_mode_case() { # name macOS swift want [env assignments...]
    local name=$1 os=$2 sw=$3 want=$4 got d="$tmp/dm-$1"
    shift 4
    mkdir -p "$d"
    printf '#!/bin/sh\necho %s\n' "$os" > "$d/sw_vers"
    printf '#!/bin/sh\necho "Apple Swift version %s (swiftlang-6000.0.1)"\n' "$sw" > "$d/swift"
    chmod +x "$d/sw_vers" "$d/swift"
    got=$(env -i PATH="$d:/usr/bin:/bin" "$@" bash -c ". '$root/engine/want-diar.sh'; diar_mode" 2>/dev/null || true)
    check "ox-diar gate mode: $name" "$got" "$want"
}
diar_mode_case "release build" 14.8 5.10 dist OX_SAY_DIST=1
diar_mode_case "release build beats a request" 26.5 6.3 dist OX_SAY_DIST=1 OX_SAY_WITH_DIAR=1
diar_mode_case "requested" 13.6 5.10 requested OX_SAY_WITH_DIAR=1
diar_mode_case "automatic" 15.7 6.3.3 auto
diar_mode_case "not wanted" 14.8 6.3.3 ""
diar_build_case() { # name macOS env-for-gate build-stub(ok|fail) check-stub(ok|fail) want-rc want-binary [env assignments...]
    local name=$1 os=$2 build=$3 chk=$4 want_rc=$5 want_bin=$6 d="$tmp/db-$1" rc=0 bin=gone
    shift 6
    mkdir -p "$d/here/diar" "$d/out" "$d/work"
    printf '#!/bin/sh\n: > "%s/out/ox-diar"\n[ %s = ok ]\n' "$d" "$build" > "$d/here/diar/build.sh"
    chmod +x "$d/here/diar/build.sh"
    printf '#!/bin/sh\necho %s\n' "$os" > "$d/sw_vers"
    printf '#!/bin/sh\necho "Apple Swift version 6.3.3 (swiftlang-6000.0.1)"\n' > "$d/swift"
    chmod +x "$d/sw_vers" "$d/swift"
    : > "$d/out/ox-diar"
    env -i PATH="$d:/usr/bin:/bin" "$@" bash -c "set -euo pipefail; . '$root/engine/want-diar.sh'
        check_static() { [ $chk = ok ] || exit 1; }; check_dist() { :; }
        diar_gate '$d/out'; diar_build '$d/here' '$d/work' '$d/out'; echo done" >"$d/log" 2>&1 || rc=$?
    if [ -e "$d/out/ox-diar" ]; then bin=left; fi
    check "ox-diar build, $name: exit status" "$rc" "$want_rc"
    check "ox-diar build, $name: binary" "$bin" "$want_bin"
}
diar_build_case "automatic, build ok" 15.7 ok ok 0 left
diar_build_case "automatic, build fails" 15.7 fail ok 0 gone
diar_build_case "automatic, post-build check fails" 15.7 ok fail 0 gone
check_in_log "automatic failure warns once and goes on" "$tmp/db-automatic, build fails/log" "warning: ox-diar did not build"
check_in_log "automatic failure names the way to force it" "$tmp/db-automatic, build fails/log" "OX_SAY_WITH_DIAR=1"
diar_build_case "requested, build fails" 15.7 fail ok 1 left OX_SAY_WITH_DIAR=1
diar_build_case "release, build fails" 15.7 fail ok 1 left OX_SAY_DIST=1
diar_build_case "release, post-build check fails" 15.7 ok fail 1 left OX_SAY_DIST=1
diar_build_case "requested, build ok" 15.7 ok ok 0 left OX_SAY_WITH_DIAR=1

# --- K: precompiled Metal libraries travel with the engines -----------------
# oxs_install_engines installs <bin>.metallib and <bin>-tensor.metallib next
# to the binary when out/ ships them; when it does not (an embedded-source
# build or a dropped engine) stale libraries an earlier install left must go —
# they would serve the wrong kernels for the new binary. Mutations
# (lib-install.sh oxs_install_engines): drop the library loop -> "metallibs
# installed" fails; drop the `else rm -f` -> "stale metallibs removed" fails;
# restore the audiocpp conditional around the cleanup -> the stale
# audiocpp_server.metallib stays -> the embed case fails.
metal_case() { # name with-audiocpp with-libs
    local d="$tmp/metal-$1" bin
    mkdir -p "$d/out/licenses" "$d/home/engine"
    echo x > "$d/out/licenses/x.LICENSE"
    for bin in tts-server ox-stt ox-align ox-llm $( [ "$2" = yes ] && echo audiocpp_server ); do
        printf '#!/bin/sh\n' > "$d/out/$bin"
        chmod +x "$d/out/$bin"
        if [ "$3" = yes ]; then
            echo lib > "$d/out/$bin.metallib"
            echo lib > "$d/out/$bin-tensor.metallib"
        fi
    done
    # What an earlier arm64 release install leaves behind: stale libraries for
    # the three engines and the whole optional VoxCPM2 pair.
    echo stale > "$d/home/engine/ox-align.metallib"
    echo stale > "$d/home/engine/ox-stt-tensor.metallib"
    printf '#!/bin/sh\n' > "$d/home/engine/audiocpp_server"
    echo stale > "$d/home/engine/audiocpp_server.metallib"
    bash -c "set -euo pipefail; . '$root/scripts/lib-install.sh'; home='$d/home'; oxs_install_engines '$d/out'" >"$d/log" 2>&1 \
        || echo "rc=$?" >>"$d/log"
    for f in "$d/home/engine"/*; do
        [ -f "$f" ] && printf '%s ' "$(basename "$f")"
    done
}
check "metallibs installed next to engines" "$(metal_case libs yes yes)" \
    "audiocpp_server audiocpp_server-tensor.metallib audiocpp_server.metallib ox-align ox-align-tensor.metallib ox-align.metallib ox-llm ox-llm-tensor.metallib ox-llm.metallib ox-stt ox-stt-tensor.metallib ox-stt.metallib tts-server tts-server-tensor.metallib tts-server.metallib "
# The stale audiocpp_server.metallib goes too: a package without the binary
# cannot leave it — the old binary it would still serve stays, but it falls
# back to its embedded source rather than load a library meant for it.
check "stale metallibs removed on embedded install" "$(metal_case embed no no)" \
    "audiocpp_server ox-align ox-llm ox-stt tts-server "

# Behaviour check for the install order: a stub mv on PATH records the
# destination of every install — each engine's libraries must land before its
# binary, so an engine respawned mid-install meets a matching pair. Mutation
# (lib-install.sh): move the binary copy above the library loop -> the order
# file shows the binary first -> RED.
metal_order_case() {
    local d="$tmp/order" bin
    mkdir -p "$d/out/licenses" "$d/home/engine" "$d/bin"
    echo x > "$d/out/licenses/x.LICENSE"
    for bin in tts-server ox-stt ox-align ox-llm audiocpp_server; do
        printf '#!/bin/sh\n' > "$d/out/$bin"
        chmod +x "$d/out/$bin"
        echo lib > "$d/out/$bin.metallib"
        echo lib > "$d/out/$bin-tensor.metallib"
    done
    printf '#!/bin/sh\necho "${2##*/}" >> "%s/order"\nexec /bin/mv "$@"\n' "$d" > "$d/bin/mv"
    chmod +x "$d/bin/mv"
    env PATH="$d/bin:$PATH" \
        bash -c "set -euo pipefail; . '$root/scripts/lib-install.sh'; home='$d/home'; oxs_install_engines '$d/out'" >"$d/log" 2>&1 \
        || echo "rc=$?" >>"$d/log"
    cat "$d/order"
}
check "each engine's metallibs install before its binary" "$(metal_order_case)" \
    "tts-server.metallib
tts-server-tensor.metallib
tts-server
ox-stt.metallib
ox-stt-tensor.metallib
ox-stt
ox-align.metallib
ox-align-tensor.metallib
ox-align
ox-llm.metallib
ox-llm-tensor.metallib
ox-llm
audiocpp_server.metallib
audiocpp_server-tensor.metallib
audiocpp_server"

# The build side cannot run in this sandbox — an engine build clones three
# trees and takes tens of minutes — so it is pinned by shape instead. The
# behavioural half lives in release.yml (AIR-target + load checks on the
# shipped libraries) and the local acceptance runs. Mutations (engine/build.sh):
# drop one copy_metal_libs -> count falls; drop an engine's EMBED_LIBRARY=ON ->
# count falls; drop the separate EMBED_LIBRARY=OFF metallib configure or the
# 14.0 library floor flag -> the count falls.
n=$(grep -cE '^[^#]*copy_metal_libs ' "$root/engine/build.sh" || true)
check "build.sh copies metallibs for all five engines" "${n:-x}" 5
n=$(grep -cE '^[^#]*-DGGML_METAL_EMBED_LIBRARY=ON' "$root/engine/build.sh" || true)
check "build.sh configures every engine binary with the embedded library" "${n:-x}" 2
n=$(grep -cE '^[^#]*-DGGML_METAL_EMBED_LIBRARY=OFF' "$root/engine/build.sh" || true)
check "build.sh keeps the separate EMBED_LIBRARY=OFF metallib configure" "${n:-x}" 1
n=$(grep -cE '^[^#]*build_metal_lib ' "$root/engine/build.sh" || true)
check "build.sh builds a metallib per ggml tree" "${n:-x}" 4
n=$(grep -cE 'GGML_METAL_MACOSX_VERSION_MIN=14.0' "$root/engine/build.sh" || true)
check "build.sh pins the metallib AIR target at 14.0" "${n:-x}" 1
# package-release.sh refuses to ship without every engine's metallib, and the
# release workflow's package check re-verifies the same list on the runner —
# a name missing from either ships the embedded-compile fallback silently.
n=$(grep -c 'ox-llm\.metallib' "$root/scripts/package-release.sh" || true)
check "package-release.sh requires ox-llm.metallib" "${n:-x}" 1
n=$(grep -c 'engine/ox-llm\.metallib' "$root/.github/workflows/release.yml" || true)
check "the release package check requires ox-llm.metallib" "${n:-x}" 1

echo
if [ "$fails" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed" >&2
    exit 1
fi
