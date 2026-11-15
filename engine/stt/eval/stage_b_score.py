"""Scores the Stage B eval (internal/daemon/boosteval_test.go output) against the spike's manifests.

    python3 -I stage_b_score.py <work> <results.jsonl>

Product-level numbers: every text is what the daemon returns (decoder boost, then the glossary post-pass), the
base arm is the same daemon with boosting off (post-pass still on). All clips are synthetic (OxSay's own TTS).

  recall            RU term clips per voice, held out (the glossary sees the OTHER voice's observed spellings),
                    written Latin form present as a whole word; "all" = 20 terms, "14" = without the six terms
                    whose spoken form is an ordinary Russian word (the spike's safe list, for comparison)
  false insertions  a written term in the output beyond what the unboosted decode already had, per 100 sentences,
                    on RU negatives (102 common-word/near-miss + 40 no-term/near-miss) and EN no-term/near-miss
  decode cost       paired per clip (boost minus base), median, in ms per second of audio (elapsed_s/duration_s)
"""
import json
import re
import statistics
import sys

TERMS = ["OxSay", "Hormozi", "Devin", "GitHub", "vaelor", "Dropbox", "Sonnet", "Haiku", "Fable", "Codex",
         "krolik", "pillow", "kisol", "dozor", "Glossa", "Claude", "Parakeet", "Brave", "Opus", "Hugging Face"]
COMMON = {"krolik", "Codex", "dozor", "Sonnet", "Opus", "Haiku"}
# Cyrillic written forms that are ordinary Russian words (lists/extra_ru.tsv): in every glossary, never to be inserted
RU_WRITTEN = ["вкратце", "пожалуйста", "сейчас"]


def has(text, term):
    return re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text) is not None


def count(text, term):
    return len(re.findall(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text))


def main(work, results):
    rows = [l.rstrip("\n").split("\t") for l in open(f"{work}/manifest_all.tsv", encoding="utf-8") if l.strip()]
    by = {}
    for l in open(results, encoding="utf-8"):
        r = json.loads(l)
        by.setdefault(r["clip"], {})[r["arm"]] = r
    out = []

    def pct(h, n):
        return f"{100 * h / max(n, 1):.1f}% ({h}/{n})"

    verdict = {}
    for voice in ("ru-ruslan", "ru-milena"):
        for name, keep in (("all 20", set(TERMS)), ("14 non-common", set(TERMS) - COMMON)):
            cl = [r for r in rows if r[1] == "term" and r[2] == "ru" and r[3] == voice and r[5] in keep and r[0] in by]
            hb = sum(has(by[r[0]]["base"]["text"], r[5]) for r in cl)
            hx = sum(has(by[r[0]]["boost"]["text"], r[5]) for r in cl)
            gain = 100 * (hx - hb) / max(len(cl), 1)
            out.append(f"RU recall {voice} ({name}): base {pct(hb, len(cl))} -> boosted {pct(hx, len(cl))}  gain {gain:+.1f} pts")
            verdict[(voice, name)] = gain
    # pooled over both voices, all 20 terms: the gate number
    cl = [r for r in rows if r[1] == "term" and r[2] == "ru" and r[0] in by]
    hb = sum(has(by[r[0]]["base"]["text"], r[5]) for r in cl)
    hx = sum(has(by[r[0]]["boost"]["text"], r[5]) for r in cl)
    pooled = 100 * (hx - hb) / max(len(cl), 1)
    out.append(f"RU recall pooled (both voices, all 20): base {pct(hb, len(cl))} -> boosted {pct(hx, len(cl))}  gain {pooled:+.1f} pts")

    en = [r for r in rows if r[1] == "term" and r[2] == "en" and r[0] in by]
    out.append(f"EN recall: base {pct(sum(has(by[r[0]]['base']['text'], r[5]) for r in en), len(en))} -> boosted "
               f"{pct(sum(has(by[r[0]]['boost']['text'], r[5]) for r in en), len(en))}")

    def fi(sel, label):
        n = tot = changed = 0
        per = {}
        for r in sel:
            if r[0] not in by:
                continue
            b, x = by[r[0]]["base"]["text"], by[r[0]]["boost"]["text"]
            n += 1
            changed += b != x
            for t in TERMS + RU_WRITTEN:
                k = max(0, count(x, t) - count(b, t))
                tot += k
                if k:
                    per[t] = per.get(t, 0) + k
        out.append(f"false insertions {label}: {tot}/{n} = {100 * tot / max(n, 1):.2f} per 100, texts changed {changed}/{n}, per term {per}")
        return tot, n

    ru = [r for r in rows if r[2] == "ru" and r[1] in ("neg", "neg2", "noterm", "nearmiss")]
    enn = [r for r in rows if r[2] == "en" and r[1] in ("noterm", "nearmiss")]
    t1, n1 = fi(ru, "RU negatives")
    t2, n2 = fi(enn, "EN negatives")
    comb = 100 * (t1 + t2) / max(n1 + n2, 1)
    out.append(f"FALSE INSERTIONS SEPARATELY: RU {100 * t1 / max(n1, 1):.2f} per 100 ({t1}/{n1}), EN {100 * t2 / max(n2, 1):.2f} per 100 ({t2}/{n2})")
    out.append(f"false insertions RU+EN combined: {t1 + t2}/{n1 + n2} = {comb:.2f} per 100")

    d_ms, b_ms, x_ms = [], [], []
    for r in rows:
        if r[0] in by and r[1] in ("term", "noterm", "nearmiss", "neg", "neg2"):
            b, x = by[r[0]]["base"], by[r[0]]["boost"]
            dur = b["duration_s"]
            if dur > 0:
                b_ms.append(1000 * b["elapsed_s"] / dur)
                x_ms.append(1000 * x["elapsed_s"] / dur)
                d_ms.append(1000 * (x["elapsed_s"] - b["elapsed_s"]) / dur)
    med = statistics.median(d_ms)
    out.append(f"decode ms per audio second over {len(d_ms)} clips: base median {statistics.median(b_ms):.1f}, boosted median "
               f"{statistics.median(x_ms):.1f}, paired extra median {med:+.2f} (mean {statistics.mean(d_ms):+.2f})")
    gate_recall = min(verdict[(v, "all 20")] for v in ("ru-ruslan", "ru-milena")) >= 20
    out.append("GATE recall >= +20 pts held out (both voices, all 20 terms): " + ("PASS" if gate_recall else "FAIL"))
    out.append("GATE false insertions <= 1 per 100 (RU+EN): " + ("PASS" if comb <= 1.0 else "FAIL"))
    out.append("GATE extra decode <= 3 ms per audio second: " + ("PASS" if med <= 3.0 else "FAIL"))
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
