#!/usr/bin/env bash
# check-arm64-baseline.sh <binary>: exit 1 if an arm64 Mach-O binary uses
# instructions an Apple M1 lacks. It scans the `otool -tv` disassembly for:
#   i8mm  smmla ummla usmmla usdot sudot
#   BF16  bfdot bfmmla bfmlalb bfmlalt bfcvt bfcvtn bfcvtn2
#   SME   smstart smstop zero rdsvl addsvl addspl fmopa/fmops smopa/umopa/...
#         and the ZA array/tiles ({za}, za0h.s, ...)
#   SVE   addvl addpl, z-registers (z0.s), predicate registers (p0/z, p1.s, pn8)
# Vector forms carry an arrangement suffix in otool output (usdot.4s,
# bfcvtn2.8h), so a mnemonic may be followed by ".<n><b|h|s|d|q>". Distribution
# builds run on every Apple Silicon Mac, and one such instruction is a SIGILL
# on an M1. A native build on a newer chip emits them: the M5 Pro's ggml carries
# ~280 smmla per engine. An otool failure fails the check (closed), so a
# non-arm64 input is a failure. scripts/check-arm64-baseline_test.sh covers it.
set -euo pipefail

bin=${1:?usage: $0 <binary>}
case $(file -b "$bin") in
    "Mach-O 64-bit executable arm64"*) : ;;
    *) echo "$bin is not an arm64 Mach-O executable — cannot verify its baseline" >&2
       exit 1 ;;
esac
disasm=$(mktemp "${TMPDIR:-/tmp}/ox-say-disasm.XXXXXX")
trap 'rm -f "$disasm"' EXIT
# Drop the trailing "; literal pool for: ..." comments: they quote string
# literals ("number with leading zero ...") that are not instructions. pipefail
# keeps an otool failure fatal.
otool -tv "$bin" | sed 's/[[:space:]]*;.*$//' >"$disasm"
# otool prints a bare mnemonic at the end of the line ("\tsmmla") or, for
# vector forms, with an arrangement suffix ("\tusdot.4s"): a mnemonic ends at
# an optional suffix, then whitespace or the end of the line.
mnemonic='smmla|ummla|usmmla|usdot|sudot|bfdot|bfmmla|bfmlal[bt]|bfcvtn?2?|smstart|smstop|zero|rdsvl|addsvl|addspl|addvl|addpl|(f|s|u|us|su|b)mop[as]'
pat="[[:space:]]($mnemonic)(\\.[0-9]*[bhsdq])?([[:space:]]|\$)"
pat="$pat|[[:space:]{]z[0-9]+(\\.|[,}[:space:]]|\$)"
pat="$pat|[[:space:]{]za[0-9]*[hv]?(\\.|[],}[:space:]]|\$)"
pat="$pat|[[:space:]]pn?[0-9]+(/|\\.|,|[[:space:]]|\$)"
# grep -c reads everything: `| grep -q` exits early, SIGPIPEs the writer and,
# under pipefail, could turn a match into a pass.
bad=$(grep -cE "$pat" "$disasm" || true)
# Anything but a clean 0 fails: a grep error leaves $bad empty.
if [ "${bad:-x}" != 0 ]; then
    echo "$bin uses instructions an Apple M1 lacks (${bad:-scan failed}); distribution builds must not" >&2
    grep -nE -m5 "$pat" "$disasm" >&2 || true
    exit 1
fi
