#!/usr/bin/env bash
# The real-model gate for ox-clean. Run it by hand before a release; CI does not and cannot.
#   engine/clean/release_check.sh <ox-clean> <models-dir>
#     <ox-clean>    the built (or packaged) binary
#     <models-dir>  what scripts/fetch-models.sh --clean-only lays out under <dest>/clean (it holds mossformer2-se-48k/)
#
# It MUST pass on a physical Apple Silicon Mac, and, for the x86_64 package, on a physical Intel Mac, before a release
# is cut. No hosted CI runner can stand in: on the macos-15 arm64 VM, Core ML on the paravirtual GPU printed nothing
# for 36 minutes in `swift test --filter ModelGoldenTests` until the job timed out (CI run 41886943007); cpuOnly is no
# way out on arm64 (the CPU fp16 defect: the known-answer check refuses it); and the hosted Intel VM cannot run Core ML
# at all (the ox-diar Intel leg failed there, run 40100359856). So the hosted jobs run the stub suite, the build and
# `test_cli.py --no-models`, and this script is where the model is exercised.
#
# It refuses to run under Rosetta (an x86_64 shell on Apple Silicon would pass as "the Intel Mac"), and when the binary's
# architecture is not the host's. Test seams (this script's own test is engine/clean/test_release_check.sh):
#   OX_CLEAN_RELEASE_FILTER   the swift test filter, default ModelGoldenTests; set but empty is refused
#
# What validates what: the arch and Rosetta checks above are about $bin. ModelGoldenTests build the sources and never run
# $bin, so on their own they say nothing about the package; test_cli.py --models (check 2) and probe_speed.sh (check 3)
# are the ones that exercise $bin with the real model.
#
# Three checks, all run even when one fails; the exit status is non-zero if any did:
#   1. ModelGoldenTests with OX_CLEAN_REQUIRE_MODELS=1 (a missing model is a failure, not a skip), and at least one
#      test actually executed: "Executed 0 tests" (a filter that matches nothing exits 0 in swift test) is a failure
#   2. the full engine/clean/test_cli.py --models, the CLI contract with the real model
#   3. engine/clean/probe_speed.sh on a synthetic 90 s clip: the speed floor of the compute plan the binary chose
# Heavy: it loads the model many times. On the shared Mac run it under the suite lock, as every Swift run:
#   /usr/bin/lockf -k -t 3600 ~/tmp/.ox-say-suite.lock nice -n 15 engine/clean/release_check.sh <ox-clean> <models-dir>
# (this script does not take the lock itself: an outer lock around an inner one would deadlock.)
set -u

bin=${1:?usage: $0 <ox-clean> <models-dir>}
models=${2:?usage: $0 <ox-clean> <models-dir>}
here=$(cd "$(dirname "$0")" && pwd)
[ -x "$bin" ] || { echo "release_check.sh: $bin is not an executable" >&2; exit 2; }
[ -d "$models/mossformer2-se-48k" ] || { echo "release_check.sh: $models has no mossformer2-se-48k/ (fetch-models.sh --clean-only <dest> lays it out under <dest>/clean)" >&2; exit 2; }
# Before anything heavy: a translated process says it is the other architecture than the hardware, so the "physical Intel
# Mac" / "physical Apple Silicon" claim of this gate would be false.
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    echo "release_check.sh: this shell runs under Rosetta, so it cannot vouch for a physical Mac; open a native Terminal and run it again" >&2
    exit 2
fi
filter=${OX_CLEAN_RELEASE_FILTER-ModelGoldenTests}
[ -n "$filter" ] || { echo "release_check.sh: the test filter is empty; refusing to run (it would match every test or none)" >&2; exit 2; }
bin=$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")
[ "$(lipo -archs "$bin" 2>/dev/null)" = "$(uname -m)" ] || { echo "release_check.sh: $bin is built for '$(lipo -archs "$bin" 2>/dev/null)', this Mac is $(uname -m); run the package that matches the hardware" >&2; exit 2; }
models=$(cd "$models" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-clean-release-check.XXXXXX") || exit 2
trap 'rm -f "$tmp/clip.wav" "$tmp/golden.log"; rmdir "$tmp" 2>/dev/null || true' EXIT

failed=()
step() { # name command...
    local name=$1
    shift
    echo "=== $name"
    if "$@"; then echo "--- ok: $name"; else echo "--- FAILED: $name" >&2; failed+=("$name"); fi
}

# `swift test` exits 0 when the filter matches nothing, so the output must show tests that ran (not skipped).
golden() {
    env OX_CLEAN_MODELS="$models" OX_CLEAN_REQUIRE_MODELS=1 \
        swift test --package-path "$here" --force-resolved-versions --filter "$filter" 2>&1 | tee "$tmp/golden.log"
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
    # the last "Executed N tests, with S tests skipped and F failures" line is the total
    local line n skipped
    line=$(grep -E 'Executed [0-9]+ tests?' "$tmp/golden.log" | tail -n 1)
    n=$(printf '%s' "$line" | sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p')
    skipped=$(printf '%s' "$line" | sed -nE 's/.*with ([0-9]+) tests? skipped.*/\1/p')
    if [ -z "$n" ] || [ "$((n - ${skipped:-0}))" -le 0 ]; then
        echo "release_check.sh: no real-model test ran (filter '$filter': ${line:-no 'Executed N tests' line in the output})" >&2
        return 1
    fi
}
step "ModelGoldenTests (OX_CLEAN_REQUIRE_MODELS=1)" golden

step "test_cli.py --models (the full CLI contract)" python3 -B "$here/test_cli.py" --bin "$bin" --models "$models"

# A synthetic voice-like clip of 90 s (test_cli.py's generator, so no recording is needed).
if python3 -B -c "
import sys
sys.path.insert(0, sys.argv[1])
import test_cli
test_cli.float_wav(sys.argv[2], test_cli.voice_like(90, seed=11))
" "$here" "$tmp/clip.wav"; then
    step "probe_speed.sh on a 90 s clip" bash "$here/probe_speed.sh" "$bin" "$models" "$tmp/clip.wav"
else
    echo "--- FAILED: could not make the synthetic clip" >&2
    failed+=("synthetic clip")
fi

echo
if [ "${#failed[@]}" -eq 0 ]; then
    echo "release_check: all checks passed on $(uname -m), macOS $(sw_vers -productVersion)"
else
    echo "release_check: FAILED: ${failed[*]}" >&2
    exit 1
fi
