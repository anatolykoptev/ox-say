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
#   * fetch-models.sh: delete the `mv ... .fluidaudio-revision` line -> a complete fetch leaves no marker (the live
#     acceptance probe sees it; this sandbox test only proves that a FAILED fetch leaves none)
#   * fetch-models.sh: change the notes sha256 -> the live acceptance probe
#     (a real copy of the model) fails; this sandbox test cannot see it, because
#     it only proves a WRONG file is refused (see Task 6 in the plan)
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

name=Qwen3.5-4B-Q4_K_M.gguf
mkdir -p "$tmp/from" "$tmp/dest"
echo "not the model" > "$tmp/from/$name"
out=$(OX_SAY_MODELS_FROM="$tmp/from" bash "$root/scripts/fetch-models.sh" --notes-only "$tmp/dest" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then pass "a wrong notes model is refused (exit $rc)"; else fail "a wrong notes model was accepted"; fi
case $out in *"checksum mismatch for $name"*) pass "the mismatch names the file" ;; *) fail "no mismatch message: $out" ;; esac
case $out in
    *fetch*) fail "--notes-only tried to download something: $out" ;;
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

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
