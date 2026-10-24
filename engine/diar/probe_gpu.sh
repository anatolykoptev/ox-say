#!/bin/bash
# Live probe: ox-diar must leave the GPU to Parakeet. Samples the accelerator's "Device Utilization %" (ioreg, no
# privileges) once a second while ox-diar diarizes a long recording, after a baseline taken with nothing running.
# Exit 0 when the busiest sample during the run stays under the baseline's busiest + 25 points.
#   engine/diar/probe_gpu.sh <ox-diar> <models-dir> <raw 16 kHz mono s16le, 5 min or longer>
# The spike's numbers on an M5 Pro: .cpuAndNeuralEngine 0 % in 14 samples, .all 80-97 %. Quit other GPU-heavy apps
# first; a baseline that is itself high makes the probe say so and stop (exit 3) instead of passing on noise.
# Mutation: Sources/ox-diar/main.swift, `ml.computeUnits = .cpuAndNeuralEngine` -> `.all` -> exit 1.
set -u
bin=${1:?usage: $0 <ox-diar> <models-dir> <pcm>}; models=${2:?}; wav=${3:?}
util() { ioreg -r -d 1 -w0 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2; }
max_of() { sort -n | tail -1; }
base=$(for _ in 1 2 3 4 5 6 7 8; do util; sleep 1; done | max_of)
if [ "${base:-100}" -gt 40 ]; then echo "baseline GPU use is already ${base:-?} %: quit what is using the GPU and run again" >&2; exit 3; fi
out=$(mktemp -d "${TMPDIR:-/tmp}/ox-diar-gpu.XXXXXX")
samples="$out/samples"
"$bin" "$wav" "$out/o.json" --models "$models" > /dev/null 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do util >> "$samples"; sleep 1; done
wait "$pid" || { echo "ox-diar failed" >&2; exit 2; }
n=$(wc -l < "$samples" | tr -d ' ')
peak=$(max_of < "$samples")
echo "baseline max $base %, during the run max ${peak:-0} % over $n samples"
rm -f "$out/o.json" "$samples"; rmdir "$out"
[ "$n" -ge 5 ] || { echo "the run was too short to sample (use a longer recording)" >&2; exit 2; }
[ "${peak:-0}" -le $((base + 25)) ]
