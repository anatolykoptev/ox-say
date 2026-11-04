#!/bin/bash
# Live probe: ox-clean must run at or above the speed floor of the compute plan it chose, and must never name the
# Neural Engine or `all`. Runs one cleaning and reads the stats line it prints on stderr.
#   engine/clean/probe_speed.sh <ox-clean> <models-dir> <mono 48 kHz float32 wav, a few minutes>
# Why this replaced diar's probe_gpu.sh: that probe sampled the accelerator's utilisation to prove ox-diar stayed OFF
# the GPU, because decision 5 of the plan put it on the Neural Engine. ox-clean is the opposite: controller decision 5
# chose cpuAndGPU (cpuOnly renders garbage on arm64; .all and the ANE are forbidden), so there is no "leave the GPU
# free" property to measure. The load that matters is speed, and the floors are per plan (decisions 5 and 8):
#   arm64 -> 50x    x86_64 cpuAndGPU (discrete GPU) -> 5x    x86_64 cpuOnly -> 2x
# The expected floor is derived HERE from `uname -m` and the units the line reports, not trusted from the line; the
# line's own `floor` must agree (SpeedFloor in ComputePlan.swift), so a floor edited in only one place fails.
# Exit 0 pass; 1 below the floor, wrong units, or the floors disagree; 2 the run failed or printed no stats line.
# Mutations (each makes this exit 1):
#   Sources/OxCleanCore/ComputePlan.swift, arm64 `units: .cpuAndGPU` -> `.all`       (units line says "all")
#   Sources/OxCleanCore/ComputePlan.swift, `appleGPU: Double = 50` -> 500             (floor disagrees, speed below it)
set -u
bin=${1:?usage: $0 <ox-clean> <models-dir> <wav>}; models=${2:?}; wav=${3:?}
out=$(mktemp -d "${TMPDIR:-/tmp}/ox-clean-speed.XXXXXX") || exit 2
trap 'rm -f "$out/o.wav" "$out/o.wav.part" "$out/err"; rmdir "$out"' EXIT
"$bin" "$wav" "$out/o.wav" --models "$models" 2> "$out/err" || { cat "$out/err" >&2; echo "ox-clean failed" >&2; exit 2; }
line=$(tail -1 "$out/err")
re='^ox-clean: ([0-9.]+) s audio in ([0-9.]+) s \(([0-9.]+)x\), load [0-9.]+ s, first prediction [0-9.]+ s, units ([A-Za-z]+), device (.+), floor ([0-9]+)x$'
if [[ ! $line =~ $re ]]; then echo "no stats line: $line" >&2; exit 2; fi
speed=${BASH_REMATCH[3]}; units=${BASH_REMATCH[4]}; floor=${BASH_REMATCH[6]}
case "$units" in
    cpuAndGPU | cpuOnly) ;;
    *) echo "FAIL: units '$units' (only cpuAndGPU or cpuOnly are allowed; never all or the Neural Engine)" >&2; exit 1 ;;
esac
case "$line" in *NeuralEngine* | *"units all"*) echo "FAIL: the stats line names the Neural Engine or all" >&2; exit 1 ;; esac
if [ "$(uname -m)" = arm64 ]; then
    [ "$units" = cpuAndGPU ] || { echo "FAIL: arm64 must run cpuAndGPU, got $units" >&2; exit 1; }
    want=50
elif [ "$units" = cpuOnly ]; then want=2; else want=5; fi
if [ "$floor" != "$want" ]; then echo "FAIL: the line says floor ${floor}x, the plan says ${want}x" >&2; exit 1; fi
echo "$line"
awk -v s="$speed" -v f="$want" 'BEGIN { exit !(s + 0 >= f + 0) }' || { echo "FAIL: ${speed}x is below the ${want}x floor of $units" >&2; exit 1; }
echo "ok: ${speed}x >= ${want}x on $units"
