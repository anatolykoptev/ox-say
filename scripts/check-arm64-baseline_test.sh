#!/usr/bin/env bash
# Test for check-arm64-baseline.sh. Assembles one small Mach-O executable per
# instruction, runs the guard on it and compares the exit status:
#   - every instruction an Apple M1 lacks (i8mm, BF16, SME, SVE) must exit 1;
#   - M1-legal controls must exit 0 (the pattern must not over-match);
#   - a disassembler that cannot decode a word (an older Xcode's otool prints SME/SVE
#     as ".long 0x...") must fail the guard closed, as must an empty disassembly;
#     a fake otool (OX_SAY_OTOOL) feeds the guard canned output for those cases;
#   - the real engine binaries, when present, are the false-positive oracle
#     (dist build -> 0) and the true-positive oracle (native M5 build -> 1).
# Prints one PASS/FAIL line per case, exits non-zero if any case failed.
# Needs an arm64 Mac with clang and otool.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
guard="$here/check-arm64-baseline.sh"
march=armv9.2-a+sme2+sve2+i8mm+bf16
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-baseline-test.XXXXXX")
cleanup() {
    rm -f "$scratch"/probe.s "$scratch"/probe "$scratch"/out "$scratch"/fake-otool "$scratch"/fake.txt
    rmdir "$scratch"
}
trap cleanup EXIT

fails=0
total=0

report() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then
        echo "PASS $1"
    else
        echo "FAIL $1 (guard exit $3, expected $2)"
        fails=$((fails + 1))
    fi
}

# probe <name> <expected-exit> <instruction>
probe() {
    local name=$1 want=$2 insn=$3 rc=0
    printf '.text\n.globl _main\n.p2align 2\n_main:\n\t%s\n\tret\n' "$insn" >"$scratch/probe.s"
    if ! clang -arch arm64 "-march=$march" "$scratch/probe.s" -o "$scratch/probe" 2>"$scratch/out"; then
        echo "FAIL $name (clang could not build the probe: $(cat "$scratch/out"))"
        total=$((total + 1))
        fails=$((fails + 1))
        return
    fi
    "$guard" "$scratch/probe" >"$scratch/out" 2>&1 || rc=$?
    report "$name" "$want" "$rc"
}

# binary <name> <expected-exit> <path>: skipped when the binary is absent.
binary() {
    local name=$1 want=$2 path=$3 rc=0
    if [ ! -f "$path" ]; then
        echo "SKIP $name ($path absent)"
        return
    fi
    "$guard" "$path" >"$scratch/out" 2>&1 || rc=$?
    report "$name" "$want" "$rc"
}

# --- forbidden: i8mm ---
probe smmla 1 'smmla v0.4s, v1.16b, v2.16b'
probe ummla 1 'ummla v0.4s, v1.16b, v2.16b'
probe usmmla 1 'usmmla v0.4s, v1.16b, v2.16b'
probe usdot-vector 1 'usdot v0.4s, v1.16b, v2.16b'
probe usdot-by-element 1 'usdot v0.4s, v1.16b, v2.4b[0]'
probe sudot-by-element 1 'sudot v0.4s, v1.16b, v2.4b[0]'
# --- forbidden: BF16 ---
probe bfdot 1 'bfdot v0.4s, v1.8h, v2.8h'
probe bfmmla 1 'bfmmla v0.4s, v1.8h, v2.8h'
probe bfmlalb 1 'bfmlalb v0.4s, v1.8h, v2.8h'
probe bfmlalt 1 'bfmlalt v0.4s, v1.8h, v2.8h'
probe bfcvtn 1 'bfcvtn v0.4h, v1.4s'
probe bfcvtn2 1 'bfcvtn2 v0.8h, v1.4s'
probe bfcvt 1 'bfcvt h0, s1'
# --- forbidden: SME ---
probe smstart 1 'smstart'
probe smstop 1 'smstop'
probe zero-za 1 'zero {za}'
probe rdsvl 1 'rdsvl x0, #1'
probe addsvl 1 'addsvl x0, x0, #1'
probe fmopa 1 'fmopa za0.s, p0/m, p1/m, z0.s, z1.s'
probe smopa 1 'smopa za0.s, p0/m, p1/m, z0.b, z1.b'
probe za-load 1 'ld1w {za0h.s[w12, 0]}, p0/z, [x0]'
probe za-tile-read 1 'mova z0.s, p0/m, za0h.s[w12, 0]'
# --- forbidden: SVE ---
probe sve-zreg 1 'add z0.s, z0.s, z1.s'
probe sve-addvl 1 'addvl x0, x0, #1'
probe sve-ptrue 1 'ptrue p0.s'
probe sve-pred-zeroing 1 'brkb p0.b, p1/z, p2.b'
# --- controls: M1-legal ---
probe ctl-sdot 0 'sdot v0.4s, v1.16b, v2.16b'
probe ctl-udot 0 'udot v0.4s, v1.16b, v2.16b'
probe ctl-sdot-by-element 0 'sdot v0.4s, v1.16b, v2.4b[0]'
probe ctl-fmla-fp16 0 'fmla v0.8h, v1.8h, v2.8h'
probe ctl-neon-add 0 'add v0.4s, v1.4s, v2.4s'
probe ctl-ld1-2d 0 'ld1 {v0.2d}, [x0]'
probe ctl-st1-2d 0 'st1 {v0.2d}, [x0]'
probe ctl-zip1 0 'zip1 v0.2d, v1.2d, v2.2d'
probe ctl-uzp1 0 'uzp1 v0.2d, v1.2d, v2.2d'
probe ctl-stlur 0 'stlur x0, [x1]'
probe ctl-prefetch 0 'prfm pldl1keep, [x0]'
probe ctl-scalar-add 0 'add x0, x0, #1'

# --- fail closed on what the disassembler cannot decode ---
# fake <name> <expected-exit> <disassembly>: the guard runs the fake otool,
# which prints <disassembly> whatever it is asked. The binary is a real arm64
# Mach-O only so that the guard's file(1) check passes.
fake() {
    local name=$1 want=$2 text=$3 rc=0
    printf '.text\n.globl _main\n.p2align 2\n_main:\n\tret\n' >"$scratch/probe.s"
    clang -arch arm64 "$scratch/probe.s" -o "$scratch/probe" 2>"$scratch/out"
    printf '%s\n' "$text" >"$scratch/fake.txt"
    printf '#!/bin/sh\ncat "%s"\n' "$scratch/fake.txt" >"$scratch/fake-otool"
    chmod +x "$scratch/fake-otool"
    OX_SAY_OTOOL="$scratch/fake-otool" "$guard" "$scratch/probe" >"$scratch/out" 2>&1 || rc=$?
    report "$name" "$want" "$rc"
}
tab=$(printf '\t')
hdr='probe:
(__TEXT,__text) section
_main:'
clean="0000000100000000${tab}add${tab}x0, x0, #0x1
0000000100000004${tab}ret"
fake fake-clean 0 "$hdr
$clean"
fake fake-undecodable-long 1 "$hdr
$clean
0000000100000008${tab}.long${tab}0x04200000"
fake fake-undecodable-inst 1 "$hdr
$clean
0000000100000008${tab}.inst${tab}0xc0080001"
fake fake-undecodable-byte 1 "$hdr
$clean
0000000100000008${tab}.byte${tab}0x01"
fake fake-undecodable-short 1 "$hdr
$clean
0000000100000008${tab}.short${tab}0x0001"
# A sign-extended negative offset (0xffff....) is data, not an instruction: a
# clean M1 build has such words (ox-stt, ox-align) and no SME/SVE/i8mm/BF16
# encoding has a 0xff top byte.
fake ctl-negative-offset-long 0 "$hdr
$clean
0000000100000008${tab}.long${tab}0xfffffe2c"
fake fake-empty-disassembly 1 "$hdr"

# --- real binaries ---
oracle=${OX_SAY_BASELINE_ORACLE:-"$HOME/tmp/ox-say-p1"}
for b in tts-server ox-stt ox-align; do
    binary "dist-$b" 0 "$oracle/engine-dist/out/$b"
done
binary native-tts-server 1 "$oracle/engine-native-s1/out/tts-server"

echo "$((total - fails))/$total passed, $fails failed"
[ "$fails" = 0 ]
