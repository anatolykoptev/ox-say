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
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-fetchtest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT
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
n=$(grep -c '^    "[0-9a-f]\{64\}  [^ ]*"$' "$root/scripts/fetch-models.sh")
if [ "$n" = 28 ]; then pass "the script lists 24 diarization files and 4 documents"; else fail "the script lists $n diarization entries, want 28"; fi

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
for combo in "--notes-only --with-whisper" "--diar-only --with-voxcpm2" "--notes-only --diar-only"; do
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

if [ -e "$tmp/nonet-calls" ]; then fail "the no-network curl stub was reached: $(cat "$tmp/nonet-calls")"; else pass "no test reached the network"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
