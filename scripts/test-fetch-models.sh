#!/bin/bash
# Sandbox test for scripts/fetch-models.sh --notes-only. Nothing is downloaded:
# OX_SAY_MODELS_FROM serves a local file, and the checksum is the pinned one,
# so a file of the wrong content must be refused. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-fetch-models.sh
#
# Mutations that must turn this RED:
#   * fetch-models.sh: delete the `models=("Qwen3.5-4B..."` line in the
#     notes_only block -> the script goes for the other models too -> "only the
#     notes model" fails
#   * fetch-models.sh: delete the `models=("${diar_models[@]}")` line under `if [ "$diar_only" = 1 ]` ->
#     --diar-only goes for the other models too -> "only the diarization models" fails
#   * fetch-models.sh: delete the `rm -f "$dest/diar/speaker-diarization/.fluidaudio-revision"` line before the loop ->
#     a failed fetch leaves an old marker -> "a failed fetch removes the marker of an earlier one" fails
#   * fetch-models.sh: delete the `mv ... .fluidaudio-revision` line -> a complete fetch leaves no marker (the live
#     acceptance probe sees it; this sandbox test only proves that a FAILED fetch leaves none)
#   * fetch-models.sh: delete the `diar/nemotron-3-diarization/*) rm -f "$nem_marker"` arm -> a bad nemotron file
#     leaves an old marker -> "its marker is gone" fails
#   * fetch-models.sh: delete the `mv ... .ox-say-revision` write -> a complete --nemotron-only fetch leaves no
#     marker -> "the nemotron marker is present after a full fetch" fails
#   * fetch-models.sh: drop `nemotron_ok` from the selection -> OX_SAY_NEMOTRON=0 still lists the nemotron set ->
#     "OX_SAY_NEMOTRON=0 skips the nemotron set" fails
#   * fetch-models.sh: put a macOS version test back in nemotron_ok (`ver=$(sw_vers -productVersion ...)`,
#     `[ "${ver%%.*}" -ge 15 ]`) -> "--diar-only on arm64 macOS 14 lists the nemotron set" and "a default run on
#     arm64 macOS 14 lists the nemotron set" fail
#   * fetch-models.sh: delete `models+=("${nem_models[@]}")` under `if [ "$diar_only" = 1 ]` ->
#     "--diar-only on arm64 macOS 15 lists the nemotron set" fails
#   * fetch-models.sh: delete `models+=("${nem_models[@]}")` under `if nemotron_ok` ->
#     "a default run on arm64 macOS 15 lists the nemotron set" fails
#   * fetch-models.sh: drop the sysctl half of the arch test in nemotron_ok -> a Rosetta shell reads as
#     Intel -> "a Rosetta shell on arm64 macOS 15 lists the nemotron set" fails
#   * fetch-models.sh: delete the `models=("${clean_models[@]}")` line under `if [ "$clean_only" = 1 ]` ->
#     --clean-only goes for the other models too -> "--clean-only lists only the clean models" fails
#   * fetch-models.sh: delete the `clean/mossformer2-se-48k/*) rm -f "$clean_marker"` arm -> a bad clean file leaves
#     an old marker -> "a failed clean fetch removes the marker of an earlier one" fails
#   * fetch-models.sh: delete the `mv ... .ox-say-revision` write of the clean set -> "the clean marker is present
#     after a full --clean-only fetch" fails
#   * fetch-models.sh: add `models+=("${clean_models[@]}")` to the default list -> "a default run on arm64 lists no
#     clean files" and "... on Intel ..." fail
#   * fetch-models.sh: change the notes sha256 -> the live acceptance probe
#     (a real copy of the model) fails; this sandbox test cannot see it, because
#     it only proves a WRONG file is refused (see Task 6 in the plan)
#   * fetch-models.sh: put `--retry 3` back into the opts of fetch_part (the `local opts=(` line) -> curl would
#     restart a stalled pass from the run's own offset -> "no curl --retry" fails
#   * fetch-models.sh: drop 28 from the `case $rc in 28 | 18 | 52 | 56)` line in fetch_part -> a stall is not
#     retried in the shell -> "a stall is resumed from the current .part" and "stalls that never end" fail
#   * fetch-models.sh: delete the `fetch_part "$base/$remote" "$part" 0` self-heal call (or the `[ "$resumed" = 1 ]`
#     guard) -> "an unresumable .part is dropped" fails
#   * fetch-models.sh: drop `-w '%{http_code}'` from the `local opts=(` line of fetch_part -> the fake curl prints no
#     status -> "the retry after a 503 resumes" and "the failure names the HTTP status" fail (the fake honours -w)
#   * fetch-models.sh: delete the `[ "$resume" = 1 ] || { resume=1; opts+=(-C -); }` line in fetch_part -> "after the
#     self-heal, a retry resumes from the fresh .part" fails
#   * fetch-models.sh: delete the `case $name in diar/*) rm -f "$diar_marker" ;; esac` line and put
#     `rm -f "$dest/diar/speaker-diarization/.fluidaudio-revision"` before the loop -> "an unrelated failure keeps the
#     marker" fails (and the delete alone makes "a failed fetch removes the marker" fail)
#   * fetch-models.sh: delete the `--notes-only ... --with-whisper` conflict check -> "an option for another set is
#     refused" fails
#   * fetch-models.sh: change `curl -fsSL` to `curl -fL` -> the fake curl prints
#     its progress meter (carriage returns) -> "no progress meter" fails
#   * fetch-models.sh: change `curl -fsSL` to `curl -fsL` -> the fake curl is
#     silent -> "curl's own error words" fails
#   * fetch-models.sh: delete the `echo "fetch   $name (found a partial download ...` line (or the `[ -s "$part" ]`
#     condition around it) -> "a rerun over a .part says what it found" / "a fresh download does not say resuming" fail
#   * fetch-models.sh: human_size, `-ge 1024` -> `-ge 1048576` for the KB arm (or MB division for all) -> "a .part under 1 MB
#     is sized in KB" fails
#   * fetch-models.sh: put the word `resuming` back into the pre-download line or the drop line -> "an unresumable .part is
#     dropped without ever saying resuming" fails
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-fetchtest.XXXXXX")
fails=0
trap 'rm -rf "${tmp:?}"' EXIT
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# Nothing here may reach the network: a curl first on PATH that fails loudly and leaves a trace. A mutant that skips
# the OX_SAY_MODELS_FROM copy (or a test that forgets its own stub) would otherwise download from Hugging Face.
mkdir -p "$tmp/nonet"
printf '#!/bin/sh\necho "curl $*" >> "%s/nonet-calls"\necho "curl: stub, no network in this test" >&2\nexit 99\n' "$tmp" > "$tmp/nonet/curl"
chmod +x "$tmp/nonet/curl"
PATH="$tmp/nonet:$PATH"

name=Qwen3.5-4B-Q4_K_M.gguf
mkdir -p "$tmp/from" "$tmp/dest"
echo "not the model" > "$tmp/from/$name"
out=$(OX_SAY_MODELS_FROM="$tmp/from" bash "$root/scripts/fetch-models.sh" --notes-only "$tmp/dest" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then pass "a wrong notes model is refused (exit $rc)"; else fail "a wrong notes model was accepted"; fi
case $out in *"checksum mismatch for $name"*) pass "the mismatch names the file" ;; *) fail "no mismatch message: $out" ;; esac
case $out in
    *"fetch   "*) fail "--notes-only tried to download something: $out" ;;
    *) pass "only the notes model is looked at" ;;
esac
if [ ! -e "$tmp/dest/$name" ] && [ ! -e "$tmp/dest/$name.part" ]; then
    pass "no model and no .part left behind"
else
    fail "files left in dest: $(ls "$tmp/dest")"
fi
case $out in *"copy    $name"*) pass "the local copy path ran for the notes model" ;; *) fail "OX_SAY_MODELS_FROM was not used: $out" ;; esac

# --diar-only: the 24 diarization files, under <dest>/diar/speaker-diarization/, nothing else, and no revision
# marker unless every file passed its checksum (FluidAudio refuses a directory without it).
rel=Embedding.mlmodelc/analytics/coremldata.bin
mkdir -p "$tmp/dfrom/diar/speaker-diarization/Embedding.mlmodelc/analytics" "$tmp/ddest"
echo "not a model" > "$tmp/dfrom/diar/speaker-diarization/$rel"
out=$(OX_SAY_MODELS_FROM="$tmp/dfrom" bash "$root/scripts/fetch-models.sh" --diar-only "$tmp/ddest" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then pass "a wrong diarization file is refused (exit $rc)"; else fail "a wrong diarization file was accepted"; fi
case $out in *"checksum mismatch for diar/speaker-diarization/$rel"*) pass "the mismatch names the diarization file" ;; *) fail "no mismatch message: $out" ;; esac
case $out in
    *qwen*|*parakeet*|*silero*|*Qwen3.5*) fail "--diar-only looked at another model: $out" ;;
    *) pass "only the diarization models are looked at" ;;
esac
if [ ! -e "$tmp/ddest/diar/speaker-diarization/.fluidaudio-revision" ] && [ ! -e "$tmp/ddest/diar/speaker-diarization/$rel" ]; then
    pass "no marker and no file left behind by a failed fetch"
else
    fail "files left in dest/diar: $(find "$tmp/ddest/diar" -type f 2>/dev/null)"
fi
# Each pinned array is counted on its own, so a new set does not touch the others' expectations (#457).
count_pins() { # array-name -> number of 64-hex SHA-256 entries inside name=( ... )
    awk -v a="$1" '$0 == a "=(" {on=1; next} on && $0 == ")" {on=0} on && /^    "[0-9a-f]{64}  [^ ]*"$/ {n++} END {print n+0}' "$root/scripts/fetch-models.sh"
}
for want in diar_files:24 diar_docs:4 nem_files:5 nem_docs:2 clean_files:8 clean_docs:4; do
    n=$(count_pins "${want%%:*}")
    if [ "$n" = "${want##*:}" ]; then pass "${want%%:*} lists $n pinned entries"; else fail "${want%%:*} lists $n pinned entries, want ${want##*:}"; fi
done

# #456: the cleanup trap must stop on an empty $tmp ("${tmp:?}"), never run a recursive delete on it, and never be find -delete.
del="-del""ete"
if grep -n "find .* $del" "$root/scripts/test-fetch-models.sh" | grep -v 'grep -n' > "$tmp/finddel"; then
    fail "this script cleans up with find $del again: $(cat "$tmp/finddel")"
else
    pass "the cleanup does not use find $del"
fi
if grep -q "^trap 'rm -rf \"\${tmp:?}\"' EXIT" "$root/scripts/test-fetch-models.sh"; then pass "the cleanup trap is rm -rf with \${tmp:?}"; else fail "the cleanup trap is not rm -rf \"\${tmp:?}\""; fi

# No model comes from a floating branch: a changed upstream file would break every new install under the pinned hashes (#437).
if grep -n 'resolve/main' "$root/scripts/fetch-models.sh" > "$tmp/floating"; then
    fail "fetch-models.sh still has resolve/main URLs: $(cat "$tmp/floating")"
else
    pass "no resolve/main URL in fetch-models.sh"
fi

# A marker from an earlier complete fetch must not outlive a failed one: the next run replaces files, and a marker over a
# half-replaced set would tell the loader the models are all there.
mkdir -p "$tmp/ddest2/diar/speaker-diarization"
echo "df2625ac79a7ac6b65ad868fee6d80f320da4232" > "$tmp/ddest2/diar/speaker-diarization/.fluidaudio-revision"
OX_SAY_MODELS_FROM="$tmp/dfrom" bash "$root/scripts/fetch-models.sh" --diar-only "$tmp/ddest2" > /dev/null 2>&1
if [ ! -e "$tmp/ddest2/diar/speaker-diarization/.fluidaudio-revision" ]; then
    pass "a failed fetch removes the marker of an earlier one"
else
    fail "the old revision marker survived a failed fetch"
fi

# Nemotron set, selected alone with --nemotron-only (the loop stops at the first bad entry, so the set under test must
# be the only one listed): its own directory and marker; a bad file there removes ITS marker and leaves the WeSpeaker
# marker alone.
mkdir -p "$tmp/ndest/diar/speaker-diarization" "$tmp/nfrom/diar/nemotron-3-diarization"
echo "df2625ac79a7ac6b65ad868fee6d80f320da4232" > "$tmp/ndest/diar/speaker-diarization/.fluidaudio-revision"
mkdir -p "$tmp/ndest/diar/nemotron-3-diarization"
echo "25a90f97f254428d4b30374b76af9c74fdee8327" > "$tmp/ndest/diar/nemotron-3-diarization/.ox-say-revision"
mkdir -p "$tmp/nfrom/diar/nemotron-3-diarization/Nemotron3Diarizer_fast128.mlmodelc"
echo "not a model" > "$tmp/nfrom/diar/nemotron-3-diarization/Nemotron3Diarizer_fast128.mlmodelc/model.mil"   # the FIRST nemotron entry
out=$(OX_SAY_NEMOTRON=1 OX_SAY_MODELS_FROM="$tmp/nfrom" bash "$root/scripts/fetch-models.sh" --nemotron-only "$tmp/ndest" 2>&1); rc=$?
[ "$rc" -ne 0 ] && pass "a wrong nemotron file is refused" || fail "a wrong nemotron file was accepted"
case $out in *"checksum mismatch for diar/nemotron-3-diarization/Nemotron3Diarizer_fast128.mlmodelc/model.mil"*) pass "the mismatch names the nemotron file" ;; *) fail "no mismatch message: $out" ;; esac
[ ! -e "$tmp/ndest/diar/nemotron-3-diarization/.ox-say-revision" ] && pass "its marker is gone" || fail "stale nemotron marker survived"
[ -e "$tmp/ndest/diar/speaker-diarization/.fluidaudio-revision" ] && pass "the WeSpeaker marker is untouched" || fail "--nemotron-only removed the WeSpeaker marker"
# gating: a Mac that cannot run ox-diar does not download 199 MB. All 28 WeSpeaker files stand in the dest already
# (the fake vouches "intact"), so the fetch walks the whole --diar-only list: with OX_SAY_NEMOTRON=0 that is 28 oks
# and done; a nemotron set still listed would go on to the no-network stub and its name would reach the output.
d="$tmp/nemgate"; mkdir -p "$d/bin" "$d/dest/diar/speaker-diarization"
cat > "$d/bin/shasum" <<FAKE
#!/bin/bash
f=\${3:-}
case \$f in
    */speaker-diarization/*)
        if [ "\$(cat "\$f")" = intact ]; then
            rel=\${f#*/speaker-diarization/}
            rel=\${rel%.part}
            sed -n '/^diar_files=(/,/^)/p; /^diar_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | grep -m1 "^    \"[0-9a-f]\{64\}  \$rel\"\$" | sed 's/^    "\([0-9a-f]*\) .*/\1  -/'
            exit 0
        fi ;;
esac
exec /usr/bin/shasum "\$@"
FAKE
chmod +x "$d/bin/shasum"
sed -n '/^diar_files=(/,/^)/p; /^diar_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed -n 's/^    "[0-9a-f]\{64\}  \(.*\)"$/\1/p' | while IFS= read -r rel; do
    mkdir -p "$d/dest/diar/speaker-diarization/$(dirname "$rel")"
    printf intact > "$d/dest/diar/speaker-diarization/$rel"
done
out=$(PATH="$d/bin:$PATH" OX_SAY_NEMOTRON=0 bash "$root/scripts/fetch-models.sh" --diar-only "$d/dest" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "OX_SAY_NEMOTRON=0 --diar-only completes"; else fail "OX_SAY_NEMOTRON=0 --diar-only failed (rc $rc): $out"; fi
case $out in *nemotron*) fail "OX_SAY_NEMOTRON=0 still listed the nemotron set: $out" ;; *) pass "OX_SAY_NEMOTRON=0 skips the nemotron set" ;; esac

# The gate itself, on faked Macs: with OX_SAY_NEMOTRON unset, nemotron_ok reads uname -m and hw.optional.arm64 (not
# the macOS version: a Mac that upgrades 14 -> 15 later must already hold the set), so fakes on PATH answer for another machine — including the Rosetta case, an x86_64
# shell on arm64 hardware (the same hw.optional.arm64 test get.sh makes). Every file the list can name is an
# "intact" copy in the from dir, so the run walks the WHOLE list: the nemotron set is listed last, and a test
# that stopped at the first entry could not tell "not listed" from "listed but never reached".
g="$tmp/nemarch"; mkdir -p "$g/bin" "$g/from"
cat > "$g/bin/shasum" <<FAKE
#!/bin/bash
f=\${3:-}
if [ "\$(cat "\$f" 2>/dev/null)" = intact ]; then
    case \$f in
        */diar/speaker-diarization/*)
            rel=\${f#*/diar/speaker-diarization/}
            rel=\${rel%.part}
            sed -n '/^diar_files=(/,/^)/p; /^diar_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | grep -m1 "^    \"[0-9a-f]\{64\}  \$rel\"\$" | sed 's/^    "\([0-9a-f]*\) .*/\1  -/'
            exit 0 ;;
        */diar/nemotron-3-diarization/*)
            rel=\${f#*/diar/nemotron-3-diarization/}
            rel=\${rel%.part}
            sed -n '/^nem_files=(/,/^)/p; /^nem_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed 's/\\\$nem_bundle/Nemotron3Diarizer_fast128.mlmodelc/g' | grep -m1 "^    \"[0-9a-f]\{64\}  \$rel\"\$" | sed 's/^    "\([0-9a-f]*\) .*/\1  -/'
            exit 0 ;;
        */*)
            name=\${f##*/}
            name=\${name%.part}
            grep -m1 "^    \"\$name [0-9a-f]\{64\} " "$root/scripts/fetch-models.sh" | sed 's/^    "[^ ]* \([0-9a-f]*\) .*/\1  -/'
            exit 0 ;;
    esac
fi
exec /usr/bin/shasum "\$@"
FAKE
chmod +x "$g/bin/shasum"
# Seed a copy of every name the default list or --diar-only can reach: the four engines at the top level,
# then the two diarization sets in their directories.
sed -n '/^models=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed -n 's/^    "\([^ ]*\) [0-9a-f]\{64\} .*/\1/p' | while IFS= read -r name; do
    printf intact > "$g/from/$name"
done
sed -n '/^diar_files=(/,/^)/p; /^diar_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed -n 's/^    "[0-9a-f]\{64\}  \(.*\)"$/\1/p' | while IFS= read -r rel; do
    mkdir -p "$g/from/diar/speaker-diarization/$(dirname "$rel")"
    printf intact > "$g/from/diar/speaker-diarization/$rel"
done
sed -n '/^nem_files=(/,/^)/p; /^nem_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed 's/\$nem_bundle/Nemotron3Diarizer_fast128.mlmodelc/g' | sed -n 's/^    "[0-9a-f]\{64\}  \(.*\)"$/\1/p' | while IFS= read -r rel; do
    mkdir -p "$g/from/diar/nemotron-3-diarization/$(dirname "$rel")"
    printf intact > "$g/from/diar/nemotron-3-diarization/$rel"
done
# fake_platform <dir> <uname -m> <sw_vers -productVersion> <hw.optional.arm64>: three fakes answering as that Mac.
fake_platform() {
    mkdir -p "$1"
    cat > "$1/uname" <<FAKE
#!/bin/sh
if [ "\${1:-}" = -m ]; then echo "$2"; else exec /usr/bin/uname "\$@"; fi
FAKE
    cat > "$1/sw_vers" <<FAKE
#!/bin/sh
if [ "\${1:-}" = -productVersion ]; then echo "$3"; else echo "sw_vers test fake: only -productVersion is known" >&2; exit 1; fi
FAKE
    cat > "$1/sysctl" <<FAKE
#!/bin/sh
if [ "\${1:-}\${2:-}" = "-nhw.optional.arm64" ]; then echo "$4"; else exec /usr/sbin/sysctl "\$@"; fi
FAKE
    chmod +x "$1/uname" "$1/sw_vers" "$1/sysctl"
}
# run_gate <fake bin> <dest> [selector]: the fetch with OX_SAY_NEMOTRON unset on the faked Mac; every listed
# file copies clean, so a name in the set reaches a copy line exactly when the gate lets the set in.
run_gate() {
    env -u OX_SAY_NEMOTRON PATH="$g/bin:$1:$PATH" OX_SAY_MODELS_FROM="$g/from" bash "$root/scripts/fetch-models.sh" ${3:+$3} "$2" 2>&1
}
# nem_listed <label> <rc> <out>: the set, listed last, was fetched — its first file on a copy line and all
# seven files past the checksum. nem_not_listed <label> <rc> <out>: no nemotron name printed, the run still 0.
nem_listed() {
    if [ "$2" != 0 ]; then fail "$1 — the run failed (rc $2): $3"; return; fi
    case $3 in
        *"copy    diar/nemotron-3-diarization/Nemotron3Diarizer_fast128.mlmodelc/model.mil"*) ;;
        *) fail "$1 — the first nemotron file reached no copy line: $3"; return ;;
    esac
    n=$(printf '%s\n' "$3" | grep -c '^ok      diar/nemotron-3-diarization/')
    if [ "$n" = 7 ]; then pass "$1"; else fail "$1 — $n of 7 nemotron files reached 'ok': $3"; fi
}
nem_not_listed() {
    case $3 in *nemotron*) fail "$1 — the nemotron set was fetched: $3"; return ;; esac
    if [ "$2" = 0 ]; then pass "$1"; else fail "$1 — the run failed (rc $2): $3"; fi
}

fake_platform "$g/arm64-15" arm64 15.1 1
out=$(run_gate "$g/arm64-15" "$g/d1" --diar-only); rc=$?
nem_listed "--diar-only on arm64 macOS 15 lists the nemotron set" "$rc" "$out"
out=$(run_gate "$g/arm64-15" "$g/d2"); rc=$?
nem_listed "a default run on arm64 macOS 15 lists the nemotron set" "$rc" "$out"

fake_platform "$g/arm64-26" arm64 26.0 1
out=$(run_gate "$g/arm64-26" "$g/d3" --diar-only); rc=$?
nem_listed "--diar-only on arm64 macOS 26 lists the nemotron set" "$rc" "$out"
out=$(run_gate "$g/arm64-26" "$g/d4"); rc=$?
nem_listed "a default run on arm64 macOS 26 lists the nemotron set" "$rc" "$out"

fake_platform "$g/arm64-14" arm64 14.7 1
out=$(run_gate "$g/arm64-14" "$g/d5" --diar-only); rc=$?
nem_listed "--diar-only on arm64 macOS 14 lists the nemotron set" "$rc" "$out"
out=$(run_gate "$g/arm64-14" "$g/d6"); rc=$?
nem_listed "a default run on arm64 macOS 14 lists the nemotron set" "$rc" "$out"

fake_platform "$g/intel-15" x86_64 15.1 0
out=$(run_gate "$g/intel-15" "$g/d7" --diar-only); rc=$?
nem_not_listed "--diar-only on Intel macOS 15 keeps the nemotron set out" "$rc" "$out"
out=$(run_gate "$g/intel-15" "$g/d8"); rc=$?
nem_not_listed "a default run on Intel macOS 15 keeps the nemotron set out" "$rc" "$out"

# A Rosetta shell is x86_64 on arm64 hardware; hw.optional.arm64 reads the hardware and still picks arm64.
fake_platform "$g/rosetta" x86_64 15.1 1
out=$(run_gate "$g/rosetta" "$g/d9" --diar-only); rc=$?
nem_listed "a Rosetta shell on arm64 macOS 15 lists the nemotron set" "$rc" "$out"

# OX_SAY_NEMOTRON=1 overrides a platform the gate would refuse.
fake_platform "$g/intel-14" x86_64 14.7 0
out=$(PATH="$g/bin:$g/intel-14:$PATH" OX_SAY_NEMOTRON=1 OX_SAY_MODELS_FROM="$g/from" bash "$root/scripts/fetch-models.sh" --diar-only "$g/d10" 2>&1); rc=$?
nem_listed "OX_SAY_NEMOTRON=1 lists the nemotron set even on Intel macOS 14" "$rc" "$out"

# The nemotron marker is written after every file of the set passed its checksum: a --nemotron-only run whose files
# all copy clean ends with .ox-say-revision naming nem_rev. The fake shasum vouches for a file holding "intact" with
# the hash the script's own nemotron table pins (the live acceptance does the same over the real files).
# Mutation: fetch-models.sh, delete the `mv ... .ox-say-revision` write -> no marker after a full fetch -> RED.
d="$tmp/nemmark"; mkdir -p "$d/bin" "$d/dest" "$d/from"
cat > "$d/bin/shasum" <<FAKE
#!/bin/bash
f=\${3:-}
case \$f in
    */nemotron-3-diarization/*)
        if [ "\$(cat "\$f")" = intact ]; then
            rel=\${f#*/nemotron-3-diarization/}
            rel=\${rel%.part}
            sed -n '/^nem_files=(/,/^)/p; /^nem_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed 's/\\\$nem_bundle/Nemotron3Diarizer_fast128.mlmodelc/g' | grep -m1 "^    \"[0-9a-f]\{64\}  \$rel\"\$" | sed 's/^    "\([0-9a-f]*\) .*/\1  -/'
            exit 0
        fi ;;
esac
exec /usr/bin/shasum "\$@"
FAKE
chmod +x "$d/bin/shasum"
sed -n '/^nem_files=(/,/^)/p; /^nem_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed 's/\$nem_bundle/Nemotron3Diarizer_fast128.mlmodelc/g' | sed -n 's/^    "[0-9a-f]\{64\}  \(.*\)"$/\1/p' | while IFS= read -r rel; do
    mkdir -p "$d/from/diar/nemotron-3-diarization/$(dirname "$rel")"
    printf intact > "$d/from/diar/nemotron-3-diarization/$rel"
done
out=$(PATH="$d/bin:$PATH" OX_SAY_MODELS_FROM="$d/from" bash "$root/scripts/fetch-models.sh" --nemotron-only "$d/dest" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "the nemotron fetch failed: $out"
if [ -e "$d/dest/diar/nemotron-3-diarization/.ox-say-revision" ] && [ "$(cat "$d/dest/diar/nemotron-3-diarization/.ox-say-revision")" = "25a90f97f254428d4b30374b76af9c74fdee8327" ]; then
    pass "the nemotron marker is present after a full fetch"
else
    fail "no nemotron marker after a full fetch (rc $rc): $out"
fi

# MossFormer2 voice-cleanup set (--clean-only): 8 files and 4 documents in <dest>/clean/mossformer2-se-48k/. Lazy: no
# default run lists it, on any Mac; only --clean-only does, on Apple Silicon and on Intel alike (no hardware gate). The
# fake shasum vouches for a file holding "intact" with the hash the script's own clean tables pin, so the 12 files count
# as passed without shipping 131 MB.
clean_tables() { sed -n '/^clean_files=(/,/^)/p; /^clean_docs=(/,/^)/p' "$root/scripts/fetch-models.sh"; }
c="$tmp/clean"; mkdir -p "$c/bin" "$c/from"
cat > "$c/bin/shasum" <<FAKE
#!/bin/bash
f=\${3:-}
case \$f in
    */clean/mossformer2-se-48k/*)
        if [ "\$(cat "\$f")" = intact ]; then
            rel=\${f#*/clean/mossformer2-se-48k/}
            rel=\${rel%.part}
            sed -n '/^clean_files=(/,/^)/p; /^clean_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | grep -m1 "^    \"[0-9a-f]\{64\}  \$rel\"\$" | sed 's/^    "\([0-9a-f]*\) .*/\1  -/'
            exit 0
        fi ;;
esac
exec /usr/bin/shasum "\$@"
FAKE
chmod +x "$c/bin/shasum"
clean_tables | sed -n 's/^    "[0-9a-f]\{64\}  \(.*\)"$/\1/p' | while IFS= read -r rel; do
    mkdir -p "$c/from/clean/mossformer2-se-48k/$(dirname "$rel")"
    printf intact > "$c/from/clean/mossformer2-se-48k/$rel"
done
cmark="clean/mossformer2-se-48k/.ox-say-revision"
crev=da0d6b45be2fe7f2ec495ee76280132848a789c0

# clean_listed <label> <rc> <out>: all 12 files of the set reached 'ok' and nothing else was looked at.
clean_listed() {
    if [ "$2" != 0 ]; then fail "$1 -- the run failed (rc $2): $3"; return; fi
    n=$(printf '%s\n' "$3" | grep -c '^ok      clean/mossformer2-se-48k/')
    other=$(printf '%s\n' "$3" | grep -E '^(ok|copy|fetch) ' | grep -vc ' clean/mossformer2-se-48k/' || true)
    if [ "$n" = 12 ] && [ "${other:-0}" = 0 ]; then pass "$1"; else fail "$1 -- $n of 12 clean files 'ok', $other other lines: $3"; fi
}
# clean_not_listed <label> <rc> <out>: no clean name printed, the run still 0.
clean_not_listed() {
    case $3 in *clean/mossformer2*) fail "$1 -- the clean set was fetched: $3"; return ;; esac
    if [ "$2" = 0 ]; then pass "$1"; else fail "$1 -- the run failed (rc $2): $3"; fi
}

out=$(PATH="$c/bin:$PATH" OX_SAY_MODELS_FROM="$c/from" bash "$root/scripts/fetch-models.sh" --clean-only "$c/dest" 2>&1); rc=$?
clean_listed "--clean-only lists only the clean models" "$rc" "$out"
if [ "$(cat "$c/dest/$cmark" 2>/dev/null)" = "$crev" ]; then pass "the clean marker is present after a full --clean-only fetch"; else fail "no clean marker after a full fetch (rc $rc): $out"; fi
if [ ! -e "$c/dest/diar" ] && [ ! -e "$c/dest/qwen-talker-0.6b-base-Q8_0.gguf" ]; then pass "--clean-only writes nothing outside the clean directory"; else fail "--clean-only wrote elsewhere: $(ls "$c/dest")"; fi
# the .mlpackage is not downloaded: the app loads the compiled .mlmodelc
case $out in *mlpackage*) fail "the .mlpackage was listed: $out" ;; *) pass "the .mlpackage is not downloaded" ;; esac

# No hardware gate: Intel (and a Rosetta shell) get the set as well.
fake_platform "$c/intel" x86_64 15.1 0
out=$(PATH="$c/bin:$c/intel:$PATH" OX_SAY_MODELS_FROM="$c/from" bash "$root/scripts/fetch-models.sh" --clean-only "$c/dest-intel" 2>&1); rc=$?
clean_listed "--clean-only on Intel lists the clean set" "$rc" "$out"

# Lazy download: a default run lists no clean files, whatever the Mac.
out=$(run_gate "$g/arm64-15" "$g/d11"); rc=$?
clean_not_listed "a default run on arm64 lists no clean files" "$rc" "$out"
out=$(run_gate "$g/intel-15" "$g/d12"); rc=$?
clean_not_listed "a default run on Intel lists no clean files" "$rc" "$out"
out=$(run_gate "$g/arm64-15" "$g/d13" --diar-only); rc=$?
clean_not_listed "--diar-only lists no clean files" "$rc" "$out"

# A bad file of the set removes ITS marker (the first listed file is wrong), and nothing of another set.
mkdir -p "$c/bad/clean/mossformer2-se-48k/MossFormer2_SE_48K.mlmodelc/analytics" "$c/bdest/clean/mossformer2-se-48k" "$c/bdest/diar/nemotron-3-diarization"
echo "not a model" > "$c/bad/clean/mossformer2-se-48k/MossFormer2_SE_48K.mlmodelc/analytics/coremldata.bin"
echo "$crev" > "$c/bdest/$cmark"
echo "25a90f97f254428d4b30374b76af9c74fdee8327" > "$c/bdest/diar/nemotron-3-diarization/.ox-say-revision"
out=$(OX_SAY_MODELS_FROM="$c/bad" bash "$root/scripts/fetch-models.sh" --clean-only "$c/bdest" 2>&1); rc=$?
[ "$rc" -ne 0 ] && pass "a wrong clean file is refused" || fail "a wrong clean file was accepted"
case $out in *"checksum mismatch for clean/mossformer2-se-48k/MossFormer2_SE_48K.mlmodelc/analytics/coremldata.bin"*) pass "the mismatch names the clean file" ;; *) fail "no mismatch message: $out" ;; esac
if [ ! -e "$c/bdest/$cmark" ]; then pass "a failed clean fetch removes the marker of an earlier one"; else fail "the old clean marker survived a failed fetch"; fi
[ -e "$c/bdest/diar/nemotron-3-diarization/.ox-say-revision" ] && pass "the clean failure leaves the nemotron marker alone" || fail "a clean failure removed the nemotron marker"
# a file that vanished from a complete set also takes the marker, and a wrong replacement fails the run
cp -R "$c/from" "$c/gone-from"
PATH="$c/bin:$PATH" OX_SAY_MODELS_FROM="$c/from" bash "$root/scripts/fetch-models.sh" --clean-only "$c/gone" > /dev/null 2>&1
if [ ! -e "$c/gone/$cmark" ]; then fail "(setup) the first clean fetch left no marker"; fi
rm "$c/gone/clean/mossformer2-se-48k/config.json"
echo "not the config" > "$c/gone-from/clean/mossformer2-se-48k/config.json"
out=$(PATH="$c/bin:$PATH" OX_SAY_MODELS_FROM="$c/gone-from" bash "$root/scripts/fetch-models.sh" --clean-only "$c/gone" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$c/gone/$cmark" ]; then pass "a missing file of a complete set removes the marker and fails the run"; else fail "gone: rc $rc: $out"; fi
# an unchanged complete set downloads nothing and keeps the marker
out=$(PATH="$c/bin:$PATH" OX_SAY_MODELS_FROM="$c/from" bash "$root/scripts/fetch-models.sh" --clean-only "$c/dest" 2>&1); rc=$?
case $out in *"copy    "*|*"fetch   "*) fail "a repeat run fetched again: $out" ;; *) [ "$rc" = 0 ] && [ "$(cat "$c/dest/$cmark")" = "$crev" ] && pass "a repeat run fetches nothing and keeps the marker" || fail "repeat: rc $rc: $out" ;; esac

# A download that fails must say why in curl's words, and must not flood stderr
# with the progress meter: the daemon shows the tail of that stderr to the user.
# The fake curl behaves like the real one: -s drops the meter and the error,
# -S brings the error back.
mkdir -p "$tmp/bin" "$tmp/dest2"
cat > "$tmp/bin/curl" <<'FAKE'
#!/bin/bash
silent=0; showerr=0
for a in "$@"; do
    case $a in
        -*s*) [[ $a == --* ]] || silent=1 ;;
    esac
    case $a in
        -*S*) [[ $a == --* ]] || showerr=1 ;;
    esac
done
[ "$silent" = 0 ] && printf '  %% Total    %% Received\r  1  100M    1 1M\r  2  100M    2 2M\r' >&2
if [ "$silent" = 0 ] || [ "$showerr" = 1 ]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
fi
exit 22
FAKE
chmod +x "$tmp/bin/curl"
out=$(PATH="$tmp/bin:$PATH" OX_SAY_MODELS_FROM= bash "$root/scripts/fetch-models.sh" --notes-only "$tmp/dest2" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then pass "a failed download fails the script (exit $rc)"; else fail "a failed download exited 0"; fi
case $out in *"returned error: 404"*) pass "curl's own error words reach stderr" ;; *) fail "no curl error in: $out" ;; esac
case $out in
    *$'\r'*|*"% Total"*) fail "the progress meter reached stderr: $out" ;;
    *) pass "no progress meter on stderr" ;;
esac

# --- option conflicts: a set selector next to an option for another set is refused, not half-obeyed ---
for combo in "--notes-only --with-whisper" "--diar-only --with-voxcpm2" "--notes-only --diar-only" "--nemotron-only --with-whisper" "--nemotron-only --diar-only" "--nemotron-only --notes-only" "--clean-only --with-whisper" "--clean-only --with-voxcpm2" "--clean-only --notes-only" "--clean-only --diar-only" "--clean-only --nemotron-only"; do
    # shellcheck disable=SC2086
    out=$(bash "$root/scripts/fetch-models.sh" $combo "$tmp/dconf" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ] && [ ! -e "$tmp/dconf" ]; then pass "an option for another set is refused ($combo)"; else fail "$combo: exit $rc, $out"; fi
done

# --- the download loop, with a scripted curl ---------------------------------------------------------------------
# The fake appends to the file after -o when it is given -C - (resume), else truncates it, like curl. Per call it
# does what $d/script says on that line: "stall:<text>" writes <text> then exits 28, "ok:<text>" writes it and
# exits 0, "rc:<n>[:<http status>]" writes nothing and exits n. It logs argv and the size of the file it was handed.
# Like curl it prints the HTTP status ONLY when it is given -w '%{http_code}' (200 after "ok", the scripted status
# after "rc:<n>:<status>", else 000), so a script that stops asking for it loses the status and the retry decisions
# that read it.
fakecurl() { # dir
    mkdir -p "$1/bin"
    cat > "$1/bin/curl" <<'FAKE'
#!/bin/bash
d=$(dirname "$(dirname "$0")")
out= resume=0 prev= wfmt=
for a in "$@"; do
    [ "$prev" = -o ] && out=$a
    [ "$prev" = -C ] && [ "$a" = - ] && resume=1
    [ "$prev" = -w ] && wfmt=$a
    prev=$a
done
status() { [ -n "$wfmt" ] && printf '%s' "${wfmt//%\{http_code\}/$1}"; return 0; }
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/n"
echo "call $n resume=$resume size=$(wc -c < "$out" 2>/dev/null | tr -d ' ') args=$*" >> "$d/calls"
line=$(sed -n "${n}p" "$d/script")
[ -n "$line" ] || line=${last:-rc:99}
kind=${line%%:*}; arg=${line#*:}; code=
case $kind:$arg in rc:*:*) code=${arg#*:}; arg=${arg%%:*} ;; esac
[ "$resume" = 1 ] || : > "$out"
case $kind in
    stall) printf '%s' "$arg" >> "$out"; status 000; exit 28 ;;
    ok) printf '%s' "$arg" >> "$out"; status 200; exit 0 ;;
    rc) status "${code:-000}"; exit "$arg" ;;
esac
FAKE
    chmod +x "$1/bin/curl"
}
run_fetch() { # dir dest
    PATH="$1/bin:$PATH" OX_SAY_MODELS_FROM='' OX_SAY_STALL_SECS=1 bash "$root/scripts/fetch-models.sh" --notes-only "$2" 2>&1
}

# A stall is resumed in the shell from what the .part holds now: pass 2 sees the 3 bytes pass 1 wrote, and no pass
# is a curl --retry (that would restart from the run's own offset).
d="$tmp/stall1"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'stall:abc\nok:defg\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in *"checksum mismatch"*) pass "a stall is resumed from the current .part, and the download completes" ;; *) fail "stall1: exit $rc: $out" ;; esac
if [ "$(wc -l < "$d/calls" | tr -d ' ')" = 2 ] && sed -n 2p "$d/calls" | grep -q 'resume=1 size=3 '; then
    pass "a stall is resumed from the current .part (pass 2 starts at byte 3)"
else
    fail "stall1 calls: $(cat "$d/calls")"
fi
if grep -q -- '--retry' "$d/calls"; then fail "curl was given --retry: $(cat "$d/calls")"; else pass "no curl --retry (the shell owns the retry)"; fi

# Stalls that never end: 4 passes (the first and 3 retries), then the stall is named, and the .part is kept for the next run.
d="$tmp/stall2"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'stall:aa\nstall:bb\nstall:cc\nstall:dd\nstall:ee\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
if [ "$rc" -ne 0 ] && [ "$(wc -l < "$d/calls" | tr -d ' ')" = 4 ]; then pass "stalls that never end stop after 4 passes (exit $rc)"; else fail "stall2: exit $rc calls=$(cat "$d/calls")"; fi
case $out in *"stalled"*) pass "the stall is named on stderr" ;; *) fail "stall2: no stall message: $out" ;; esac
if [ "$(cat "$d/dest/$name.part" 2>/dev/null)" = aabbccdd ]; then pass "the partial download is kept for the next run"; else fail "stall2 .part: $(cat "$d/dest/$name.part" 2>/dev/null)"; fi

# A .part the server refuses to resume (curl exit 22 on HTTP 416): dropped, fetched once from the start, no -C.
d="$tmp/heal"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'stale bytes that no longer fit' > "$d/dest/$name.part"
printf 'rc:22:416\nok:fresh\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in *"checksum mismatch"*) pass "an unresumable .part is dropped and the file fetched from the start" ;; *) fail "heal: exit $rc: $out" ;; esac
if sed -n 2p "$d/calls" | grep -q 'resume=0 size= '; then pass "the second try is a fresh download, not a resume"; else fail "heal calls: $(cat "$d/calls")"; fi
# After the self-heal the fresh download is itself resumed when it stalls: pass 2 sees the bytes pass 1 wrote and
# sends -C - (it must not start over from byte 0 on every retry).
d="$tmp/heal2"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'stale bytes that no longer fit' > "$d/dest/$name.part"
printf 'rc:22:416\nstall:abc\nok:defg\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in *"checksum mismatch"*) pass "a stall after the self-heal completes" ;; *) fail "heal2: exit $rc: $out" ;; esac
if [ "$(wc -l < "$d/calls" | tr -d ' ')" = 3 ] && sed -n 2p "$d/calls" | grep -q 'resume=0 size= ' && sed -n 3p "$d/calls" | grep -q 'resume=1 size=3 '; then
    pass "after the self-heal, a retry resumes from the fresh .part (-C -)"
else
    fail "heal2 calls: $(cat "$d/calls")"
fi
# A 503 is transient: retried with the .part kept and -C - on the retry; a 404 keeps the .part and is not retried.
d="$tmp/t503"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'keep' > "$d/dest/$name.part"
printf 'rc:22:503\nok:rest\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in *"checksum mismatch"*) pass "a 503 on a resume is retried and the download completes" ;; *) fail "t503: exit $rc: $out" ;; esac
if [ "$(wc -l < "$d/calls" | tr -d ' ')" = 2 ] && sed -n 2p "$d/calls" | grep -q 'resume=1 size=4 '; then
    pass "the retry after a 503 resumes from the kept .part"
else
    fail "t503 calls: $(cat "$d/calls")"
fi
d="$tmp/t404"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'keep' > "$d/dest/$name.part"
printf 'rc:22:404\nok:x\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
if [ "$rc" -ne 0 ] && [ "$(wc -l < "$d/calls" | tr -d ' ')" = 1 ] && [ "$(cat "$d/dest/$name.part")" = keep ]; then
    pass "a 404 is not retried and keeps the .part"
else
    fail "t404: exit $rc calls=$(cat "$d/calls") part=$(cat "$d/dest/$name.part" 2>/dev/null)"
fi
case $out in *"HTTP 404"*) pass "the failure names the HTTP status" ;; *) fail "t404 message: $out" ;; esac
# ... but an empty or missing .part that fails is a plain failure, with no second try.
d="$tmp/noheal"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'rc:22\nok:x\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
if [ "$rc" -ne 0 ] && [ "$(wc -l < "$d/calls" | tr -d ' ')" = 1 ]; then pass "a failure with nothing to resume is not retried"; else fail "noheal: exit $rc calls=$(cat "$d/calls")"; fi
case $out in *"failed (curl exit 22)"*) pass "the failure names curl's exit status" ;; *) fail "noheal: $out" ;; esac

# The marker: a failure on an unrelated model, before the diarization files, must not take the marker of intact
# diarization files with it. The fake shasum vouches for a file holding "intact" with the pinned hash from the script's
# own table, so the 28 files count as passed without shipping 22 MB of models.
d="$tmp/marker"; mkdir -p "$d/bin" "$d/dest/diar/speaker-diarization" "$d/from"
cat > "$d/bin/shasum" <<FAKE
#!/bin/bash
f=\${3:-}
case \$f in
    */speaker-diarization/*)
        if [ "\$(cat "\$f")" = intact ]; then
            rel=\${f#*/speaker-diarization/}
            grep -m1 "^    \"[0-9a-f]\{64\}  \$rel\"\\$" "$root/scripts/fetch-models.sh" | sed 's/^    "\([0-9a-f]*\) .*/\1  -/'
            exit 0
        fi ;;
esac
exec /usr/bin/shasum "\$@"
FAKE
chmod +x "$d/bin/shasum"
grep '^    "[0-9a-f]\{64\}  ' "$root/scripts/fetch-models.sh" | sed 's/^    "[0-9a-f]*  \(.*\)"$/\1/' | while IFS= read -r rel; do
    mkdir -p "$d/dest/diar/speaker-diarization/$(dirname "$rel")"
    printf intact > "$d/dest/diar/speaker-diarization/$rel"
done
echo df2625ac79a7ac6b65ad868fee6d80f320da4232 > "$d/dest/diar/speaker-diarization/.fluidaudio-revision"
echo "not the model" > "$d/from/qwen-talker-0.6b-base-Q8_0.gguf"
PATH="$d/bin:$PATH" OX_SAY_MODELS_FROM="$d/from" bash "$root/scripts/fetch-models.sh" "$d/dest" > "$d/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'checksum mismatch for qwen-talker' "$d/out"; then pass "(setup) an unrelated model fails first"; else fail "marker setup: exit $rc: $(cat "$d/out")"; fi
if [ -e "$d/dest/diar/speaker-diarization/.fluidaudio-revision" ]; then
    pass "an unrelated failure keeps the marker of intact diarization files"
else
    fail "an unrelated failure removed the diarization marker"
fi

# #356: a slow download is not silent. The installer's output reaches the app's log, and the app ends an install whose
# log stays still for 25 minutes; curl runs with -s, so fetch-models.sh itself prints "progress <file> <bytes>" while a
# file downloads. The fake curl grows the .part in two steps 3 s apart; with OX_SAY_PROGRESS_SECS=1 two lines carry two
# different sizes. Mutation: delete the `progress_tick "$part" &` line in fetch_part -> no line -> RED.
d="$tmp/slow"; mkdir -p "$d/bin" "$d/dest"
cat > "$d/bin/curl" <<'FAKE'
#!/bin/bash
out= prev=
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
printf 12345 >> "$out"; sleep 3; printf 67890 >> "$out"; sleep 3
printf 200
FAKE
chmod +x "$d/bin/curl"
out=$(PATH="$d/bin:$PATH" OX_SAY_MODELS_FROM='' OX_SAY_PROGRESS_SECS=1 bash "$root/scripts/fetch-models.sh" --notes-only "$d/dest" 2>&1)
lines=$(printf '%s\n' "$out" | grep -c '^progress Qwen3.5-4B-Q4_K_M.gguf.part [0-9]* bytes$' || true)
sizes=$(printf '%s\n' "$out" | sed -n 's/^progress Qwen3.5-4B-Q4_K_M.gguf.part \([0-9]*\) bytes$/\1/p' | sort -u | wc -l | tr -d ' ')
if [ "${lines:-0}" -ge 2 ] && [ "${sizes:-0}" -ge 2 ]; then pass "a slow download prints progress lines with growing sizes"; else fail "progress lines: $lines lines, $sizes sizes in: $out"; fi
if pgrep -f "$d/bin" >/dev/null 2>&1; then fail "the progress ticker outlived the download"; else pass "the progress ticker stops with the download"; fi

# #299.c1: the ticker follows its parent. A Ctrl-C of a terminal install kills the script while the ticker runs on its
# own; it must notice within one tick (1 s here) and stop printing. The script is SIGKILLed mid-download (the fake curl
# hangs), then the output file must stop growing. Mutation: delete the `kill -0 "$parent"` line in progress_tick ->
# the ticker prints on after its parent is gone -> RED.
d="$tmp/orphan"; mkdir -p "$d/bin" "$d/dest"
cat > "$d/bin/curl" <<'FAKE'
#!/bin/bash
echo $$ > "$ORPHAN_CURL_PID"
exec sleep 30
FAKE
chmod +x "$d/bin/curl"
ORPHAN_CURL_PID="$d/curl.pid" PATH="$d/bin:$PATH" OX_SAY_MODELS_FROM='' OX_SAY_PROGRESS_SECS=1 \
    bash "$root/scripts/fetch-models.sh" --notes-only "$d/dest" > "$d/out" 2>&1 &
script=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q "^progress" "$d/out" && break; sleep 1; done
if grep -q "^progress" "$d/out"; then
    kill -9 "$script" 2>/dev/null || true
    wait "$script" 2>/dev/null || true
    sleep 3 # one tick to notice, one to spare
    before=$(wc -l < "$d/out" | tr -d ' ')
    sleep 3
    after=$(wc -l < "$d/out" | tr -d ' ')
    if [ "$before" = "$after" ]; then pass "the progress ticker stops when its parent is killed"; else fail "the ticker printed on after its parent died ($before -> $after lines)"; fi
else
    kill -9 "$script" 2>/dev/null || true
    fail "no progress line appeared within 10 s; cannot test the orphaned ticker"
fi
[ -s "$d/curl.pid" ] && kill "$(cat "$d/curl.pid")" 2>/dev/null || true

# A rerun over a .part says what it found, and how much (#372.2): the log of a restart and of a continuation must differ.
# It does not say "resuming" (#384.4): that is known only when the server answers, and a .part it refuses is dropped.
d="$tmp/resumeline"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
dd if=/dev/zero of="$d/dest/$name.part" bs=1048576 count=3 2>/dev/null
printf 'ok:rest\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in
    *"fetch   $name (found a partial download, 3 MB; trying to continue it)"*) pass "a rerun over a .part says what it found, and how many MB" ;;
    *) fail "resumeline: exit $rc: $out" ;;
esac
if printf '%s\n' "$out" | grep -qx "fetch   $name"; then fail "a continuation also printed the fresh-download line: $out"; else pass "a continuation does not claim to be a fresh fetch"; fi
if sed -n 1p "$d/calls" | grep -q 'resume=1 size=3145728 '; then pass "and the download did resume from those bytes"; else fail "resumeline calls: $(cat "$d/calls")"; fi
# A .part under 1 MB is sized in KB (or bytes), never "from 0 MB".
d="$tmp/smallpart"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
dd if=/dev/zero of="$d/dest/$name.part" bs=1024 count=100 2>/dev/null
printf 'ok:rest\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in
    *"0 MB"*) fail "a small .part was sized in MB: $out" ;;
    *"found a partial download, 100 KB;"*) pass "a .part under 1 MB is sized in KB" ;;
    *) fail "smallpart: exit $rc: $out" ;;
esac
d="$tmp/tinypart"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'abc' > "$d/dest/$name.part"
printf 'ok:rest\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in *"found a partial download, 3 bytes;"*) pass "a .part under 1 KB is sized in bytes" ;; *) fail "tinypart: exit $rc: $out" ;; esac
d="$tmp/onebyte"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'a' > "$d/dest/$name.part"
printf 'ok:rest\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in *"found a partial download, 1 byte;"*) pass "a one-byte .part is sized '1 byte', not '1 bytes'" ;; *) fail "onebyte: exit $rc: $out" ;; esac
# A .part the server then refuses (HTTP 416) is never announced as "resuming", before or after it is dropped.
d="$tmp/noresume"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'stale bytes that no longer fit' > "$d/dest/$name.part"
printf 'rc:22:416\nok:fresh\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in
    *"resuming"*) fail "an unresumable .part was announced as resuming: $out" ;;
    *"cannot be continued (curl exit 22, HTTP 416); fetching it again from the start"*) pass "an unresumable .part is dropped without ever saying resuming" ;;
    *) fail "noresume: exit $rc: $out" ;;
esac
d="$tmp/freshline"; mkdir -p "$d" "$d/dest"
fakecurl "$d"
printf 'ok:all\n' > "$d/script"
out=$(run_fetch "$d" "$d/dest"); rc=$?
case $out in
    *"resuming "*) fail "a fresh download said resuming: $out" ;;
    *"fetch   $name"*) pass "a fresh download does not say resuming" ;;
    *) fail "freshline: exit $rc: $out" ;;
esac

if [ -e "$tmp/nonet-calls" ]; then fail "the no-network curl stub was reached: $(cat "$tmp/nonet-calls")"; else pass "no test reached the network"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
