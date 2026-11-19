#!/bin/bash
# Sandbox test for scripts/fetch-models.sh --notes <file> <sha256> <url>. Nothing is downloaded:
# OX_SAY_MODELS_FROM serves a local file, and the checksum is the pinned one,
# so a file of the wrong content must be refused. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-fetch-models.sh
#
# Mutations that must turn this RED:
#   * fetch-models.sh: delete the `models=("Qwen3.5-4B..."` line in the
#     notes_only block -> the script goes for the other models too -> "only the
#     notes model" fails
#   * fetch-models.sh: delete the `models=("${nem_models[@]}")` line under `if [ "$diar_only" = 1 ]` ->
#     --diar-only goes for the other models too -> "only the diarization models" fails
#   * fetch-models.sh: delete the leftover-folder `echo "note ...speaker-diarization..."` -> "a leftover pyannote folder
#     is named" fails; make it `rm` the folder -> "a leftover pyannote folder is not deleted" fails
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
#   * fetch-models.sh: put `rm -f "$nem_marker"` before the loop -> "an unrelated failure keeps the marker" fails
#   * fetch-models.sh: delete the `ggml-parakeet-ultra-f16.bin | */ggml-parakeet-ultra-f16.bin) with_parakeet_f16=1`
#     arm of the OX_SAY_STT_MODEL case -> an update by get.sh no longer keeps the f16 file -> "OX_SAY_STT_MODEL naming
#     the f16 file fetches it with no flag" fails
#   * fetch-models.sh: change the f16 SHA-256 or the parakeet_f16 revision -> "the f16 entry carries the pinned SHA-256" /
#     "the f16 file is downloaded from the pinned revision URL" fail
#   * fetch-models.sh: delete the `notes_only ... with_whisper` conflict check -> "an option for another set is
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
# The daemon names the notes model: file name, pinned sha256, pinned resolve URL (the catalog's 4B row here).
notes_sha=00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4
notes_url=https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523
mkdir -p "$tmp/from" "$tmp/dest"
echo "not the model" > "$tmp/from/$name"
out=$(OX_SAY_MODELS_FROM="$tmp/from" bash "$root/scripts/fetch-models.sh" --notes "$name" "$notes_sha" "$notes_url" "$tmp/dest" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then pass "a wrong notes model is refused (exit $rc)"; else fail "a wrong notes model was accepted"; fi
case $out in *"checksum mismatch for $name"*) pass "the mismatch names the file" ;; *) fail "no mismatch message: $out" ;; esac
case $out in
    *"fetch   "*) fail "--notes tried to download something: $out" ;;
    *) pass "only the notes model is looked at" ;;
esac
if [ ! -e "$tmp/dest/$name" ] && [ ! -e "$tmp/dest/$name.part" ]; then
    pass "no model and no .part left behind"
else
    fail "files left in dest: $(ls "$tmp/dest")"
fi
case $out in *"copy    $name"*) pass "the local copy path ran for the notes model" ;; *) fail "OX_SAY_MODELS_FROM was not used: $out" ;; esac

# --notes refuses a malformed call at the option, before any file is copied or any URL is fetched: a non-.gguf or
# path-shaped file name, a sha that is not 64 lowercase hex, a non-Hugging-Face-resolve URL, missing arguments and a
# second --notes all exit 2 with a usage error and leave nothing behind. Mutation: fetch-models.sh, delete the
# `*[!0-9a-f]*` sha arm -> "a --notes call with a non-hex sha is refused" fails; delete the hf URL arm -> "...with a
# non-HF URL..." fails.
mkdir -p "$tmp/baddest"
bad_notes() { # label, --notes args...
    label=$1; shift
    out=$(OX_SAY_MODELS_FROM="$tmp/from" bash "$root/scripts/fetch-models.sh" "$@" "$tmp/baddest" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then pass "$label"; else fail "$label: exit $rc, $out"; fi
    case $out in *"--notes"*) ;; *) fail "$label: no usage error: $out" ;; esac
}
bad_notes "a --notes call with a non-.gguf name is refused" --notes model.bin "$notes_sha" "$notes_url"
bad_notes "a --notes call with a path for a name is refused" --notes sub/model.gguf "$notes_sha" "$notes_url"
bad_notes "a --notes call with a non-hex sha is refused" --notes "$name" zzzz "$notes_url"
bad_notes "a --notes call with a short sha is refused" --notes "$name" 00fe "$notes_url"
bad_notes "a --notes call with an uppercase sha is refused" --notes "$name" "$(printf '%s' "$notes_sha" | tr 'a-f' 'A-F')" "$notes_url"
bad_notes "a --notes call with a non-HF URL is refused" --notes "$name" "$notes_sha" "https://example.com/x.gguf"
bad_notes "a --notes call with a floating-branch URL is refused" --notes "$name" "$notes_sha" "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/blob/main/$name"
bad_notes "a --notes call with a resolve/<branch> URL is refused" --notes "$name" "$notes_sha" "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main"
bad_notes "a --notes call with a resolve/<tag> URL is refused" --notes "$name" "$notes_sha" "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/v1.0.0"
bad_notes "--notes with missing arguments is refused" --notes "$name" "$notes_sha"
out=$(OX_SAY_MODELS_FROM="$tmp/from" bash "$root/scripts/fetch-models.sh" --notes "$name" "$notes_sha" "$notes_url" --notes "$name" "$notes_sha" "$notes_url" "$tmp/baddest" 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then pass "a second --notes is refused"; else fail "a second --notes: exit $rc, $out"; fi
if [ ! -e "$tmp/baddest/$name" ] && [ ! -e "$tmp/baddest/$name.part" ]; then
    pass "a refused --notes left nothing in dest"
else
    fail "a refused --notes wrote: $(ls "$tmp/baddest")"
fi
if [ ! -e "$tmp/nonet-calls" ]; then pass "a refused --notes never reached the network"; else fail "a refused --notes called curl"; fi

# --diar-only: the Nemotron set (on an Apple Silicon Mac), under <dest>/diar/nemotron-3-diarization/, nothing else, and no
# revision marker unless every file passed its checksum.
rel=Nemotron3Diarizer_fast128.mlmodelc/model.mil
mkdir -p "$tmp/dfrom/diar/nemotron-3-diarization/Nemotron3Diarizer_fast128.mlmodelc" "$tmp/ddest"
echo "not a model" > "$tmp/dfrom/diar/nemotron-3-diarization/$rel"
out=$(OX_SAY_NEMOTRON=1 OX_SAY_MODELS_FROM="$tmp/dfrom" bash "$root/scripts/fetch-models.sh" --diar-only "$tmp/ddest" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then pass "a wrong diarization file is refused (exit $rc)"; else fail "a wrong diarization file was accepted"; fi
case $out in *"checksum mismatch for diar/nemotron-3-diarization/$rel"*) pass "the mismatch names the diarization file" ;; *) fail "no mismatch message: $out" ;; esac
case $out in
    *qwen*|*parakeet*|*silero*|*Qwen3.5*|*speaker-diarization*) fail "--diar-only looked at another model: $out" ;;
    *) pass "only the diarization models are looked at" ;;
esac
if [ ! -e "$tmp/ddest/diar/nemotron-3-diarization/.ox-say-revision" ] && [ ! -e "$tmp/ddest/diar/nemotron-3-diarization/$rel" ]; then
    pass "no marker and no file left behind by a failed fetch"
else
    fail "files left in dest/diar: $(find "$tmp/ddest/diar" -type f 2>/dev/null)"
fi
# Each pinned array is counted on its own, so a new set does not touch the others' expectations (#457).
count_pins() { # array-name -> number of 64-hex SHA-256 entries inside name=( ... )
    awk -v a="$1" '$0 == a "=(" {on=1; next} on && $0 == ")" {on=0} on && /^    "[0-9a-f]{64}  [^ ]*"$/ {n++} END {print n+0}' "$root/scripts/fetch-models.sh"
}
for want in nem_files:5 nem_docs:2 clean_files:8 clean_docs:4; do
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

# Nemotron set, selected alone with --nemotron-only (the loop stops at the first bad entry, so the set under test must
# be the only one listed): its own directory and marker; a bad file there removes ITS marker (a marker from an earlier
# complete fetch must not outlive a failed one) and leaves the folder of the removed pyannote set alone.
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
[ -e "$tmp/ndest/diar/speaker-diarization/.fluidaudio-revision" ] && pass "a leftover pyannote folder is untouched" || fail "--nemotron-only removed the leftover pyannote marker"
# gating: a Mac that cannot run ox-diar does not download 199 MB. With OX_SAY_NEMOTRON=0 the diarization set is empty,
# so --diar-only has nothing to fetch and says so, with no network call (the stub curl would fail the run) and no
# nemotron name in the output.
out=$(OX_SAY_NEMOTRON=0 bash "$root/scripts/fetch-models.sh" --diar-only "$tmp/nemgate" 2>&1); rc=$?
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
# then the diarization set in its directory.
sed -n '/^models=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed -n 's/^    "\([^ ]*\) [0-9a-f]\{64\} .*/\1/p' | while IFS= read -r name; do
    printf intact > "$g/from/$name"
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

# A folder left by the pyannote engine is named and never deleted: a default run on an Apple Silicon Mac that holds one
# prints a note naming it, leaves its files and marker where they are, and does not list its files as models. A Mac
# without one gets no note. Mutation: fetch-models.sh, delete the leftover `echo "note ..."` -> "a leftover pyannote folder
# is named" fails; replace it with `rm -r "$old"` -> "a leftover pyannote folder is not deleted" fails.
mkdir -p "$g/dleft/diar/speaker-diarization/Embedding.mlmodelc"
echo old > "$g/dleft/diar/speaker-diarization/Embedding.mlmodelc/model.mil"
echo df2625ac79a7ac6b65ad868fee6d80f320da4232 > "$g/dleft/diar/speaker-diarization/.fluidaudio-revision"
out=$(run_gate "$g/arm64-15" "$g/dleft"); rc=$?
[ "$rc" = 0 ] || fail "a default run beside a leftover pyannote folder failed (rc $rc): $out"
case $out in *"note    $g/dleft/diar/speaker-diarization"*) pass "a leftover pyannote folder is named" ;; *) fail "no note for the leftover pyannote folder: $out" ;; esac
if [ -f "$g/dleft/diar/speaker-diarization/Embedding.mlmodelc/model.mil" ] && [ -f "$g/dleft/diar/speaker-diarization/.fluidaudio-revision" ]; then
    pass "a leftover pyannote folder is not deleted"
else
    fail "the leftover pyannote folder lost files"
fi
out=$(run_gate "$g/arm64-15" "$g/dclean"); rc=$?
case $out in *speaker-diarization*) fail "a Mac without the old folder got a note: $out" ;; *) pass "no note without a leftover pyannote folder" ;; esac

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
out=$(PATH="$tmp/bin:$PATH" OX_SAY_MODELS_FROM='' bash "$root/scripts/fetch-models.sh" --notes "$name" "$notes_sha" "$notes_url" "$tmp/dest2" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then pass "a failed download fails the script (exit $rc)"; else fail "a failed download exited 0"; fi
case $out in *"returned error: 404"*) pass "curl's own error words reach stderr" ;; *) fail "no curl error in: $out" ;; esac
case $out in
    *$'\r'*|*"% Total"*) fail "the progress meter reached stderr: $out" ;;
    *) pass "no progress meter on stderr" ;;
esac

# --- option conflicts: a set selector next to an option for another set is refused, not half-obeyed ---
for combo in "--notes $name $notes_sha $notes_url --with-whisper" "--diar-only --with-voxcpm2" "--notes $name $notes_sha $notes_url --diar-only" "--nemotron-only --with-whisper" "--nemotron-only --diar-only" "--nemotron-only --notes $name $notes_sha $notes_url" "--clean-only --with-whisper" "--clean-only --with-voxcpm2" "--clean-only --notes $name $notes_sha $notes_url" "--clean-only --diar-only" "--clean-only --nemotron-only"; do
    # shellcheck disable=SC2086
    out=$(bash "$root/scripts/fetch-models.sh" $combo "$tmp/dconf" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ] && [ ! -e "$tmp/dconf" ]; then pass "an option for another set is refused ($combo)"; else fail "$combo: exit $rc, $out"; fi
done

# --- parakeet-ultra f16 (--with-parakeet-f16, or OX_SAY_STT_MODEL naming the file) --------------------------------
# The expected SHA-256, size and revision are typed here from the Hub's own answer (x-linked-etag, x-linked-size,
# x-repo-commit of a HEAD on the file URL), not read back out of fetch-models.sh, so a wrong pin there is caught.
f16_name=ggml-parakeet-ultra-f16.bin
f16_sha=ee42f83ae751d7b3f9c435543df92ea6926f2d73df3129186a1ab58a8c7b6150
f16_url=https://huggingface.co/Koptev/parakeet-ultra-ggml/resolve/2d1259722b0a0ee0d525aaaadcd648de58641dc0/$f16_name
q8_url=https://huggingface.co/Koptev/parakeet-ultra-ggml/resolve/376105ac643ed20ac1e6cb54c2c04c454294c5a9
if grep -qF "\"$f16_name $f16_sha \$parakeet_f16\"" "$root/scripts/fetch-models.sh"; then pass "the f16 entry carries the pinned SHA-256"; else fail "the f16 entry is not $f16_name $f16_sha"; fi
if grep -q "^parakeet=$q8_url\$" "$root/scripts/fetch-models.sh"; then pass "the q8_0 pin did not move"; else fail "the q8_0 revision is not $q8_url"; fi
# Every default-list file is an "intact" copy in $g/from (the loop would stop at the first one it could not get); the f16
# file is NOT there, so a run that wants it reaches the scripted curl, which hands back "intact" and logs the URL.
f16=$tmp/f16; mkdir -p "$f16/bin"
cat > "$f16/bin/shasum" <<FAKE
#!/bin/bash
f=\${3:-}
case \$f in
    */$f16_name*) if [ "\$(cat "\$f")" = intact ]; then echo "$f16_sha  -"; exit 0; fi ;;
esac
exec "$g/bin/shasum" "\$@"
FAKE
chmod +x "$f16/bin/shasum"
f16_curl() { # dir
    mkdir -p "$1/bin"
    cat > "$1/bin/curl" <<'FAKE'
#!/bin/bash
out= prev= wfmt=
for a in "$@"; do
    [ "$prev" = -o ] && out=$a
    [ "$prev" = -w ] && wfmt=$a
    prev=$a
done
echo "$*" >> "$(dirname "$(dirname "$0")")/calls"
printf intact > "$out"
[ -n "$wfmt" ] && printf '%s' "${wfmt//%\{http_code\}/200}"
exit 0
FAKE
    chmod +x "$1/bin/curl"
}
f16_curl "$f16"
# run_f16 <dest> <OX_SAY_STT_MODEL or -> [fetch-models.sh args]: the default list, no Nemotron, f16 only via flag or env.
run_f16() {
    local dest=$1 model=$2 setting=()
    shift 2
    [ "$model" = - ] || setting=("$model")
    env -u OX_SAY_STT_MODEL ${setting[@]+"${setting[@]}"} OX_SAY_NEMOTRON=0 PATH="$f16/bin:$PATH" OX_SAY_MODELS_FROM="$g/from" bash "$root/scripts/fetch-models.sh" "$@" "$dest" 2>&1
}
f16_calls() { grep -c "$f16_url" "$f16/calls" 2>/dev/null || true; }

out=$(run_f16 "$f16/a" - --with-parakeet-f16); rc=$?
if [ "$rc" = 0 ] && [ -f "$f16/a/$f16_name" ] && [ -f "$f16/a/ggml-parakeet-ultra-q8_0.bin" ]; then pass "--with-parakeet-f16 fetches the f16 file and keeps the q8_0 default"; else fail "--with-parakeet-f16 (rc $rc): $out"; fi
case $out in *"ok      $f16_name"*) pass "--with-parakeet-f16 verifies the f16 file ('ok')" ;; *) fail "no ok line for the f16 file: $out" ;; esac
n=$(f16_calls)
if [ "$n" = 1 ]; then pass "the f16 file is downloaded from the pinned revision URL"; else fail "the f16 URL $f16_url was requested $n times: $(cat "$f16/calls" 2>/dev/null)"; fi

: > "$f16/calls"
out=$(run_f16 "$f16/b" -); rc=$?
case $out in *"$f16_name"*) fail "a default run listed the f16 file: $out" ;; *) [ "$rc" = 0 ] && pass "a default run does not fetch the f16 file" || fail "default run failed (rc $rc): $out" ;; esac
out=$(run_f16 "$f16/c" "OX_SAY_STT_MODEL=/Users/someone/Library/Application Support/ox-say/models/ggml-parakeet-ultra-q8_0.bin"); rc=$?
case $out in *"$f16_name"*) fail "OX_SAY_STT_MODEL naming q8_0 pulled the f16 file: $out" ;; *) [ "$rc" = 0 ] && pass "OX_SAY_STT_MODEL naming the q8_0 file does not fetch f16" || fail "q8_0 run failed (rc $rc): $out" ;; esac

# The update path: get.sh runs fetch-models.sh with no flag and the agent's OX_SAY_STT_MODEL exported.
out=$(run_f16 "$f16/d" "OX_SAY_STT_MODEL=/Users/someone/Library/Application Support/ox-say/models/$f16_name"); rc=$?
if [ "$rc" = 0 ] && [ -f "$f16/d/$f16_name" ]; then pass "OX_SAY_STT_MODEL naming the f16 file fetches it with no flag"; else fail "env-named f16 (rc $rc): $out"; fi
case $out in *"ok      $f16_name"*) pass "the env-named f16 file is verified ('ok')" ;; *) fail "no ok line for the env-named f16 file: $out" ;; esac
out=$(run_f16 "$f16/e" "OX_SAY_STT_MODEL=$f16_name"); rc=$?
if [ "$rc" = 0 ] && [ -f "$f16/e/$f16_name" ]; then pass "a bare f16 file name in OX_SAY_STT_MODEL also matches"; else fail "bare-name f16 (rc $rc): $out"; fi
# Already in place and intact: verified again, no second download.
before=$(f16_calls)
out=$(run_f16 "$f16/d" "OX_SAY_STT_MODEL=/x/$f16_name"); rc=$?
case $out in
    *"fetch   $f16_name"* | *"copy    $f16_name"*) fail "an intact f16 file was fetched again: $out" ;;
    *"ok      $f16_name"*) [ "$(f16_calls)" = "$before" ] && pass "an f16 file already in place is verified, not downloaded again" || fail "curl was called again for a present f16 file" ;;
    *) fail "present f16 file: rc $rc: $out" ;;
esac
# The flag is for the default set only.
for combo in "--notes $name $notes_sha $notes_url --with-parakeet-f16" "--diar-only --with-parakeet-f16" "--nemotron-only --with-parakeet-f16" "--clean-only --with-parakeet-f16"; do
    # shellcheck disable=SC2086
    out=$(bash "$root/scripts/fetch-models.sh" $combo "$f16/conf" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ] && [ ! -e "$f16/conf" ]; then pass "an option for another set is refused ($combo)"; else fail "$combo: exit $rc, $out"; fi
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
    PATH="$1/bin:$PATH" OX_SAY_MODELS_FROM='' OX_SAY_STALL_SECS=1 bash "$root/scripts/fetch-models.sh" --notes "$name" "$notes_sha" "$notes_url" "$2" 2>&1
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
# own table, so the 7 files count as passed without shipping 199 MB of models.
d="$tmp/marker"; mkdir -p "$d/bin" "$d/dest/diar/nemotron-3-diarization" "$d/from"
cat > "$d/bin/shasum" <<FAKE
#!/bin/bash
f=\${3:-}
case \$f in
    */nemotron-3-diarization/*)
        if [ "\$(cat "\$f")" = intact ]; then
            rel=\${f#*/nemotron-3-diarization/}
            sed -n '/^nem_files=(/,/^)/p; /^nem_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed 's/\\\$nem_bundle/Nemotron3Diarizer_fast128.mlmodelc/g' | grep -m1 "^    \"[0-9a-f]\{64\}  \$rel\"\$" | sed 's/^    "\([0-9a-f]*\) .*/\1  -/'
            exit 0
        fi ;;
esac
exec /usr/bin/shasum "\$@"
FAKE
chmod +x "$d/bin/shasum"
sed -n '/^nem_files=(/,/^)/p; /^nem_docs=(/,/^)/p' "$root/scripts/fetch-models.sh" | sed 's/\$nem_bundle/Nemotron3Diarizer_fast128.mlmodelc/g' | sed -n 's/^    "[0-9a-f]\{64\}  \(.*\)"$/\1/p' | while IFS= read -r rel; do
    mkdir -p "$d/dest/diar/nemotron-3-diarization/$(dirname "$rel")"
    printf intact > "$d/dest/diar/nemotron-3-diarization/$rel"
done
echo 25a90f97f254428d4b30374b76af9c74fdee8327 > "$d/dest/diar/nemotron-3-diarization/.ox-say-revision"
echo "not the model" > "$d/from/qwen-talker-0.6b-base-Q8_0.gguf"
PATH="$d/bin:$PATH" OX_SAY_NEMOTRON=1 OX_SAY_MODELS_FROM="$d/from" bash "$root/scripts/fetch-models.sh" "$d/dest" > "$d/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'checksum mismatch for qwen-talker' "$d/out"; then pass "(setup) an unrelated model fails first"; else fail "marker setup: exit $rc: $(cat "$d/out")"; fi
if [ -e "$d/dest/diar/nemotron-3-diarization/.ox-say-revision" ]; then
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
out=$(PATH="$d/bin:$PATH" OX_SAY_MODELS_FROM='' OX_SAY_PROGRESS_SECS=1 bash "$root/scripts/fetch-models.sh" --notes "$name" "$notes_sha" "$notes_url" "$d/dest" 2>&1)
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
    bash "$root/scripts/fetch-models.sh" --notes "$name" "$notes_sha" "$notes_url" "$d/dest" > "$d/out" 2>&1 &
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
