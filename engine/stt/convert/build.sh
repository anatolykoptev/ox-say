#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 OxSay (anatolykoptev/ox-say). Licensed under the Apache License, Version 2.0.
#
# The steps that produced ggml-parakeet-ultra-q8_0.bin. Run it in an empty scratch directory.
# This file was written from the build logs and the scripts' arguments after the build; the
# original shell history was not kept, and this script as a whole has not been re-run. See
# PROVENANCE.md for what was checked on the real outputs.
#
# Python: 3.12, torch, safetensors, numpy, PyYAML (the build used torch 2.15.0, safetensors 0.8.0,
# numpy 2.5.5, PyYAML 6.0.3). Tools: git, cmake, a C++ toolchain, the `hf` CLI.
set -euo pipefail

ULTRA_REV=73175eb7aeb0d82f1e2a6b53b3aabc10a90bcd0b   # moondream/parakeet-ultra
V3_REV=541d1f99c6b0c3cd0b11a95167540bb8edefd82b      # nvidia/parakeet-tdt-0.6b-v3
WCPP_REV=6e4ab854f67f743900934a703d5603419384c961    # ggml-org/whisper.cpp
HERE=$(cd "$(dirname "$0")" && pwd)

# 1. Inputs, pinned to the revisions above.
hf download moondream/parakeet-ultra model.safetensors config.json tokenizer.json \
    --revision "$ULTRA_REV" --local-dir dl-ultra
hf download nvidia/parakeet-tdt-0.6b-v3 parakeet-tdt-0.6b-v3.nemo \
    --revision "$V3_REV" --local-dir dl-v3
echo "c9608f36d0ab956c14bfcc525479b0746b3b42a56f6949ec85c14eb7466717dc  dl-ultra/model.safetensors" | shasum -a 256 -c -
echo "3cbdc85877e668ca7b82d0d56770eb1fac76691f55d6b97545e8d61ca588d10d  dl-v3/parakeet-tdt-0.6b-v3.nemo" | shasum -a 256 -c -

# 2. moondream's HF-transformers key names -> NeMo key names (a pure rename; the 6 vad_head.*
#    tensors have no NeMo destination and are left out). The featurizer tensors, the model
#    config and the tokenizer files are taken from the v3 .nemo.
python3 "$HERE/hf2nemo.py" --ref-nemo dl-v3/parakeet-tdt-0.6b-v3.nemo \
    --hf dl-ultra/model.safetensors --out ultra.nemo --workdir ultra-extract

# 3. whisper.cpp at the pinned commit: the NeMo -> ggml converter (f32, so nothing is rounded)
#    and parakeet-quantize.
git clone https://github.com/ggml-org/whisper.cpp
git -C whisper.cpp checkout "$WCPP_REV"
cmake -S whisper.cpp -B whisper.cpp/build -DGGML_METAL=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build whisper.cpp/build --target parakeet-quantize -j 4
mkdir -p models
python3 whisper.cpp/models/convert-parakeet-to-ggml.py --model ultra.nemo --out-dir models \
    --out-name ultra-f32.bin --use-f32
whisper.cpp/build/bin/parakeet-quantize models/ultra-f32.bin models/ggml-parakeet-ultra-q8_0.bin q8_0

shasum -a 256 models/ggml-parakeet-ultra-q8_0.bin   # expect the value in manifest.json
