#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 OxSay (anatolykoptev/ox-say). Licensed under the Apache License, Version 2.0.
"""Check the files listed in manifest.json against the files next to it.

  python3 -I convert/verify_manifest.py [repo_dir]

Prints one line per entry (OK / MISSING / MISMATCH) and exits 1 if any listed file that is
present has the wrong size or SHA-256, or if a model file is missing. Entries of manifest.json
under "files" with "optional": true may be absent (for example the variants still to come).
"""
import hashlib, json, os, sys

root = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
manifest = json.load(open(os.path.join(root, "manifest.json"), encoding="utf-8"))
bad = 0
for entry in manifest["files"]:
    path = os.path.join(root, entry["name"])
    if not os.path.exists(path):
        print(("SKIP    " if entry.get("optional") else "MISSING ") + entry["name"])
        bad += 0 if entry.get("optional") else 1
        continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    ok = h.hexdigest() == entry["sha256"] and os.path.getsize(path) == entry["bytes"]
    print(("OK      " if ok else "MISMATCH ") + entry["name"])
    bad += 0 if ok else 1
sys.exit(1 if bad else 0)
