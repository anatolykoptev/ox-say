"""Score the term-boost eval: python3 -I boost_score.py <work-dir> [--json]

Reads <work>/manifest.tsv and <work>/out/<arm>/<clip>.json (+ .err for decode_ms). Arms: base (no flags),
a0 (--terms-stdin --boost-alpha 0), a1 a2 a3, and for the self-checks tiny (alpha 1e-6, a token
reference) and huge (alpha 30).

Metrics, per arm
  recall RU / EN  share of term clips whose output holds the term, whole word, case exact
  FI/100          listed terms found, whole word, case exact, in the no-term and near-miss outputs, per
                  100 of those sentences (a hit there is a false insertion: the reference has none)
  decode ms       mean and median per clip, from the `decode_ms=` line of `ox-stt -v`
Acoustic veto (computed after the fact, no extra decode): for a boosted arm and a floor, an occurrence of
a listed term whose span overlaps a token the boost CHANGED with raw p below the floor is dropped, as if
the decoder had kept the unboosted word. Floors 0 (= the arm itself), 0.01, 0.05.

Self-checks
  identity   base and a0 give the same JSON (elapsed_s masked) on every clip
  silence    huge alpha adds no words to the silence clips and none to the silence padding of sp-* clips
  raw p      with huge alpha, every token before the first boosted one has the id and raw p of the tiny
             reference; a boosted token's raw p never exceeds the reference argmax token's p
"""
import json
import os
import re
import statistics
import sys

TERMS = ["OxSay", "Hormozi", "Devin", "GitHub", "vaelor", "Dropbox", "Sonnet", "Haiku", "Fable", "Codex",
         "krolik", "pillow", "kisol", "dozor", "Glossa", "Claude", "Parakeet", "Brave", "Opus", "Hugging Face"]
ARMS = ["base", "a0", "a1", "a2", "a3"]
FLOORS = [0.0, 0.01, 0.05]


def find_all(text, term):
    pat = r"(?<!\w)" + r"\s+".join(re.escape(w) for w in term.split()) + r"(?!\w)"
    return [m.span() for m in re.finditer(pat, text)]


def load(work, arm, clip):
    p = os.path.join(work, "out", arm, clip + ".json")
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def decode_ms(work, arm, clip):
    p = os.path.join(work, "out", arm, clip + ".err")
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            m = re.findall(r"decode_ms=([0-9.]+)", f.read())
        return float(m[-1]) if m else None
    except OSError:
        return None


def token_text(tokens):
    """The tokens as text plus each token's character span in it ("▁" is a space)."""
    s, spans = "", []
    for t in tokens:
        piece = t["t"].replace("▁", " ")
        spans.append((len(s), len(s) + len(piece)))
        s += piece
    return s, spans


def occurrences(doc, terms, floor):
    """Listed-term occurrences in the clip's output, minus the vetoed ones."""
    toks = doc.get("tokens")
    if floor <= 0 or not toks:
        return [(t, sp) for t in terms for sp in find_all(doc["text"], t)]
    text, spans = token_text(toks)
    out = []
    for t in terms:
        for a, b in find_all(text, t):
            vetoed = any(tok["boosted"] and tok["p"] < floor and s < b and e > a
                         for tok, (s, e) in zip(toks, spans))
            if not vetoed:
                out.append((t, (a, b)))
    return out


def evaluate(work, rows, arm, floor):
    hit = {"ru": [0, 0], "en": [0, 0]}
    fi = n_fi = 0
    ms = []
    missing = 0
    for clip, kind, lang, _voice, _text, terms in rows:
        d = load(work, arm, clip)
        if d is None:
            missing += 1
            continue
        m = decode_ms(work, arm, clip)
        if m is not None:
            ms.append(m)
        if kind == "term":
            want = terms.split("|")[0]
            ok = any(t == want for t, _ in occurrences(d, [want], floor))
            hit[lang][0] += ok
            hit[lang][1] += 1
        else:
            n_fi += 1
            fi += len(occurrences(d, TERMS, floor))
    return {
        "arm": arm, "floor": floor, "missing": missing,
        "recall_ru": 100.0 * hit["ru"][0] / hit["ru"][1] if hit["ru"][1] else None, "n_ru": hit["ru"][1],
        "recall_en": 100.0 * hit["en"][0] / hit["en"][1] if hit["en"][1] else None, "n_en": hit["en"][1],
        "fi_per_100": 100.0 * fi / n_fi if n_fi else None, "n_sent": n_fi,
        "ms_mean": statistics.mean(ms) if ms else None, "ms_median": statistics.median(ms) if ms else None,
    }


def mask(doc):
    d = dict(doc)
    d.pop("elapsed_s", None)
    return json.dumps(d, sort_keys=True, ensure_ascii=False)


def selfchecks(work, rows):
    res = {}
    clips = [r[0] for r in rows]
    # identity: a0 == base
    diffs = [c for c in clips if load(work, "base", c) and load(work, "a0", c) and
             mask(load(work, "base", c)) != mask(load(work, "a0", c))]
    n = sum(1 for c in clips if load(work, "base", c) and load(work, "a0", c))
    res["identity"] = {"clips": n, "differ": diffs[:5], "n_differ": len(diffs)}
    # silence and silence padding
    allc = sorted(os.listdir(os.path.join(work, "out", "huge"))) if os.path.isdir(os.path.join(work, "out", "huge")) else []
    sil = {"clips": 0, "extra_words": [], "silence_text": None}
    for f in allc:
        if not f.endswith(".json"):
            continue
        c = f[:-5]
        if not (c.startswith("sp-") or c == "silence"):
            continue
        h, b = load(work, "huge", c), load(work, "base", c)
        if h is None or b is None:
            continue
        sil["clips"] += 1
        if c == "silence":
            sil["silence_text"] = h["text"]
        elif len(h["words"]) > len(b["words"]):
            sil["extra_words"].append(c)
    res["silence"] = sil
    # raw p
    rp = {"clips": 0, "prefix_mismatch": [], "boosted_p_above_ref": [], "boosted_tokens": 0}
    for c in clips:
        h, t = load(work, "huge", c), load(work, "tiny", c)
        if h is None or t is None or "tokens" not in h or "tokens" not in t:
            continue
        rp["clips"] += 1
        for i, tok in enumerate(h["tokens"]):
            if i >= len(t["tokens"]):
                break
            ref = t["tokens"][i]
            if tok["boosted"]:
                rp["boosted_tokens"] += 1
                if tok["p"] > ref["p"] + 1e-6:
                    rp["boosted_p_above_ref"].append((c, i))
                break  # past the first change the two decodes diverge
            if tok["id"] != ref["id"] or abs(tok["p"] - ref["p"]) > 1e-6:
                rp["prefix_mismatch"].append((c, i))
                break
    res["raw_p"] = rp
    return res


def main():
    work = sys.argv[1]
    rows = [line.rstrip("\n").split("\t") for line in open(os.path.join(work, "manifest.tsv"), encoding="utf-8")]
    rows = [r + [""] * (6 - len(r)) for r in rows]
    base = evaluate(work, rows, "base", 0.0)
    table = [base]
    for arm in ARMS[1:]:
        table.append(evaluate(work, rows, arm, 0.0))
    for arm in ARMS[2:]:
        for fl in FLOORS[1:]:
            table.append(evaluate(work, rows, arm, fl))
    chk = selfchecks(work, rows)
    if "--json" in sys.argv:
        json.dump({"table": table, "checks": chk}, sys.stdout, ensure_ascii=False, indent=1, default=str)
        return
    print("| arm | veto floor | recall RU % | recall EN % | FI /100 | decode ms mean | median | missing |")
    print("|---|---|---|---|---|---|---|---|")
    for r in table:
        f = lambda v, n=1: "-" if v is None else f"{v:.{n}f}"
        print(f"| {r['arm']} | {r['floor']:g} | {f(r['recall_ru'])} | {f(r['recall_en'])} | {f(r['fi_per_100'])} | "
              f"{f(r['ms_mean'])} | {f(r['ms_median'])} | {r['missing']} |")
    print()
    print(json.dumps(chk, ensure_ascii=False, indent=1, default=str))
    b = base["ms_median"]
    print("\nGate: RU recall >= base + 20 points at an arm with FI <= 1/100 and decode time < +5%")
    for r in table[2:]:
        if r["recall_ru"] is None or base["recall_ru"] is None:
            continue
        up = r["recall_ru"] - base["recall_ru"]
        slow = (r["ms_median"] / b - 1) * 100 if b and r["ms_median"] else float("nan")
        ok = up >= 20 and (r["fi_per_100"] or 0) <= 1 and slow < 5
        print(f"  {r['arm']} floor {r['floor']:g}: RU {up:+.1f} pts, FI {r['fi_per_100']:.1f}, "
              f"time {slow:+.1f}% -> {'PASS' if ok else 'fail'}")


if __name__ == "__main__":
    main()
