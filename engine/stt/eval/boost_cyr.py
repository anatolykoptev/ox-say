"""Spoken-form (Cyrillic alias) part of the term-boost eval.

    python3 -I boost_cyr.py corpus <work>   # manifest_neg.tsv: 102 new RU negatives (common-word aliases, near-misses)
    python3 -I boost_cyr.py lists  <work>   # lists/{U,Usafe,A,Asafe,B,Bsafe}.tsv
    python3 -I boost_cyr.py score  <work>   # tables

Lists (term lines, "written<TAB>spoken..."): hand = the standard Cyrillic transliteration of each term
(HAND below, written before looking at any ox-stt output); obs-<voice> = what Parakeet WROTE for the term
in that voice's base (unboosted) decode, cut out of the known template. A = hand + obs(ru-milena) is
scored on ru-ruslan clips, B = hand + obs(ru-ruslan) on ru-milena clips: the held-out halves. U = hand +
both voices, for the negatives and EN clips (the worst case for false insertions). *safe drops the terms
that are common Russian words (COMMON), which only ship if the negatives show them safe.
"""
import json
import os
import random
import re
import statistics
import sys

SEED = 20261115
TERMS = ["OxSay", "Hormozi", "Devin", "GitHub", "vaelor", "Dropbox", "Sonnet", "Haiku", "Fable", "Codex",
         "krolik", "pillow", "kisol", "dozor", "Glossa", "Claude", "Parakeet", "Brave", "Opus", "Hugging Face"]
HAND = {"OxSay": "Оксей", "Hormozi": "Хормози", "Devin": "Девин", "GitHub": "Гитхаб", "vaelor": "Вейлор",
        "Dropbox": "Дропбокс", "Sonnet": "Соннет", "Haiku": "Хайку", "Fable": "Фейбл", "Codex": "Кодекс",
        "krolik": "Кролик", "pillow": "Пиллоу", "kisol": "Кисол", "dozor": "Дозор", "Glossa": "Глосса",
        "Claude": "Клод", "Parakeet": "Паракит", "Brave": "Брейв", "Opus": "Опус", "Hugging Face": "Хаггинг Фейс"}
COMMON = {"krolik", "Codex", "dozor", "Sonnet", "Opus", "Haiku"}  # rabbit, code, patrol, sonnet, opus, haiku
RU_T = ["Я вчера читал про {T} и остался доволен.", "Самое важное на сегодня, это {T}.",
        "{T} уже работает, можешь проверить."]
NEG_W = ["кролик", "кролика", "кролику", "кроликов", "кодекс", "кодекса", "кодексу", "дозор", "дозорный",
         "дозорного", "дозоре", "сонет", "сонета", "сонеты", "опус", "опуса", "Клод Моне", "хайку"]
NEG_T = ["Вчера мы долго говорили про {W} за ужином.", "На картинке в книге я увидел {W}.",
         "Он сказал слово {W} и замолчал.", "Мне кажется, {W} здесь совсем не к месту.",
         "Расскажи мне подробнее про {W}, пожалуйста."]
NEAR = ["Мы поехали до загородного дома.", "Дорога до загородного кафе заняла час.", "Мы дошли до зоркого взгляда.",
        "Это было до зарплаты.", "Я доехал до зоны отдыха.", "Мы дошли до озера.", "Она дошла до дорогого магазина.",
        "Он шёл до сонного городка.", "Я дошёл до кодовой двери.", "Мы добрались до коробки.",
        "Надо дотерпеть до хорошей погоды.", "Он дошёл до опытного врача."]
VOICES = ["ru-milena", "ru-ruslan"]


def norm(s):
    return re.sub(r"[^\w ]", "", s.lower().replace("ё", "е")).split()


def words_in(text, phrase):
    w, p = norm(text), norm(phrase)
    return any(w[i:i + len(p)] == p for i in range(len(w) - len(p) + 1)) if p else False


def manifest(work):
    return [l.rstrip("\n").split("\t") for l in open(os.path.join(work, "manifest.tsv"), encoding="utf-8")]


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def corpus(work):
    rng = random.Random(SEED)
    sents = [NEG_T[i % 5].format(W=w) for w in NEG_W for i in range(5)] + NEAR
    rows = []
    for i, s in enumerate(sents):
        rows.append((f"cn{i:03d}", "neg", "ru", VOICES[i % 2], s, ""))
    rng.shuffle(rows)  # voices stay attached to their sentence; only the order changes
    write(os.path.join(work, "manifest_neg.tsv"), "".join("\t".join(r) + "\n" for r in rows))
    print(len(rows), "negatives")


def observed(work, voice):
    """What Parakeet wrote for each term in `voice`'s unboosted decode, cut out of the template."""
    obs = {t: [] for t in TERMS}
    for r in manifest(work):
        if r[1] != "term" or r[2] != "ru" or r[3] != voice:
            continue
        term = r[5]
        tpl = next(t for t in RU_T if t.format(T=term) == r[4])
        pre, suf = tpl.split("{T}")
        pre, suf = " ".join(norm(pre)), " ".join(norm(suf))
        got = " ".join(norm(json.load(open(os.path.join(work, "out", "base", r[0] + ".json"), encoding="utf-8"))["text"]))
        m = re.fullmatch(re.escape(pre) + r"\s*(.+?)\s*" + re.escape(suf), got) if pre else \
            re.fullmatch(r"(.+?)\s*" + re.escape(suf), got)
        if not m:
            continue
        span = m.group(1)
        if re.search("[а-я]", span) and len(span.split()) <= 3 and len(span) >= 3 and span not in obs[term]:
            obs[term].append(span)
    return obs


def listing(work):
    d = os.path.join(work, "lists")
    os.makedirs(d, exist_ok=True)
    om, orr = observed(work, "ru-milena"), observed(work, "ru-ruslan")

    def build(sources):
        out = []
        for t in TERMS:
            al = [HAND[t]]
            for src in sources:
                al += [a for a in src[t] if a not in [x.lower() for x in al] and a != HAND[t].lower()]
            out.append((t, al))
        return out

    for name, srcs in {"U": [om, orr], "A": [om], "B": [orr]}.items():
        full = build(srcs)
        write(os.path.join(d, name + ".tsv"), "".join(t + "\t" + "\t".join(a) + "\n" for t, a in full))
        write(os.path.join(d, name + "safe.tsv"),
              "".join(t + "\t" + "\t".join(a) + "\n" for t, a in full if t not in COMMON))
    write(os.path.join(d, "obs.json"), json.dumps({"ru-milena": om, "ru-ruslan": orr}, ensure_ascii=False, indent=1))
    print(open(os.path.join(d, "U.tsv"), encoding="utf-8").read())


def load_list(path):
    out = {}
    for l in open(path, encoding="utf-8"):
        p = l.rstrip("\n").split("\t")
        out[p[0]] = p[1:]
    return out


def doc(work, arm, clip):
    p = os.path.join(work, "out", arm, clip + ".json")
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None


def ms(work, arm, clips):
    v = []
    for c in clips:
        p = os.path.join(work, "out", arm, c + ".err")
        if os.path.exists(p):
            m = re.findall(r"decode_ms=([0-9.]+)", open(p, errors="replace").read())
            if m:
                v.append(float(m[-1]))
    return statistics.median(v) if v else None


def recall(work, arm, rows, lst, voice, terms_ok):
    """term clips of `voice`: base counts a whole-word alias OR the written form; boosted arms count the written form
    in the mapped text OR an alias left in it (the list's own forms, same map for both)."""
    h = n = 0
    for r in rows:
        if r[1] != "term" or r[2] != "ru" or r[3] != voice or r[5] not in terms_ok:
            continue
        d = doc(work, arm, r[0])
        if d is None:
            continue
        n += 1
        t = r[5]
        h += words_in(d["text"], t) or any(words_in(d["text"], a) for a in lst[t])
    return h, n


def fi(work, arm, rows, written, clips_kind):
    """Written (Latin) forms in the output beyond what the unboosted decode already had, per 100 sentences."""
    tot = n = changed = 0
    per = {}
    for r in rows:
        if r[1] not in clips_kind:
            continue
        d, b = doc(work, arm, r[0]), doc(work, "base", r[0])
        if d is None or b is None:
            continue
        n += 1
        changed += d.get("text_raw", d["text"]) != b["text"]
        for t in written:
            k = max(0, len(re.findall(r"(?<!\w)" + re.escape(t) + r"(?!\w)", d["text"])) -
                    len(re.findall(r"(?<!\w)" + re.escape(t) + r"(?!\w)", b["text"])))
            tot += k
            if k:
                per[t] = per.get(t, 0) + k
    return tot, n, changed, per


def score(work):
    rows = manifest(work) + [r for r in (l.rstrip("\n").split("\t") for l in open(os.path.join(work, "manifest_neg.tsv"), encoding="utf-8"))]
    d = os.path.join(work, "lists")
    out = []
    alphas = [1, 2, 3]
    for voice, lname in (("ru-ruslan", "A"), ("ru-milena", "B")):
        for suf in ("", "safe"):
            lst = load_list(os.path.join(d, lname + suf + ".tsv"))
            full_all = load_list(os.path.join(d, lname + ".tsv"))
            ok = set(lst)
            bh, bn = recall(work, "base", rows, full_all, voice, ok)
            out.append(f"held-out {voice} (list {lname}{suf}, {len(ok)} terms)  base {100*bh/max(bn,1):.1f}% ({bh}/{bn})")
            for a in alphas:
                h, n = recall(work, f"h{lname}{suf}-a{a}", rows, full_all, voice, ok)
                out.append(f"   alpha {a}: {100*h/max(n,1):.1f}% ({h}/{n})  gain {100*(h/max(n,1)-bh/max(bn,1)):+.1f} pts")
    for suf in ("", "safe"):
        lst = load_list(os.path.join(d, "U" + suf + ".tsv"))
        written = list(lst)
        neg_all = {"neg"}
        ru_old = {"noterm", "nearmiss"}
        for a in alphas:
            arm = f"U{suf}-a{a}"
            t1, n1, c1, p1 = fi(work, arm, [r for r in rows if r[2] == "ru"], written, neg_all)
            t2, n2, c2, p2 = fi(work, arm, [r for r in rows if r[2] == "ru"], written, ru_old)
            t3, n3, c3, p3 = fi(work, arm, [r for r in rows if r[2] == "en"], written, ru_old)
            tn = t1 + t2
            nn = n1 + n2
            out.append(f"list U{suf} alpha {a}: RU negatives (new {n1} + old {n2}) FI {tn}/{nn} = {100*tn/max(nn,1):.1f}/100, "
                       f"changed text {c1+c2}/{nn}; per term {dict(sorted({**p1, **{k: p1.get(k,0)+v for k,v in p2.items()}}.items()))}; "
                       f"EN no-term/near-miss FI {t3}/{n3}")
    # EN recall and RU recall with the mixed list, all RU term clips (not held out: the list is U)
    for suf in ("", "safe"):
        lst = load_list(os.path.join(d, "U" + suf + ".tsv"))
        full = load_list(os.path.join(d, "U.tsv"))
        for a in [0] + alphas:
            arm = "base" if a == 0 else f"U{suf}-a{a}"
            enh = enn = 0
            for r in rows:
                if r[1] == "term" and r[2] == "en" and r[5] in lst:
                    dd = doc(work, arm, r[0])
                    if dd:
                        enn += 1
                        enh += bool(re.search(r"(?<!\w)" + re.escape(r[5]) + r"(?!\w)", dd["text"]))
            rh = rn = 0
            for v in VOICES:
                h, n = recall(work, arm, rows, full, v, set(lst))
                rh += h
                rn += n
            out.append(f"mixed list U{suf} alpha {a}: EN written recall {100*enh/max(enn,1):.1f}% ({enh}/{enn}), "
                       f"RU recall (in-sample aliases) {100*rh/max(rn,1):.1f}% ({rh}/{rn})")
    allc = [r[0] for r in rows if r[1] in ("term", "noterm", "nearmiss", "neg")]
    for arm in ["base"] + [f"U{s}-a{a}" for s in ("", "safe") for a in alphas]:
        out.append(f"decode ms median {arm}: {ms(work, arm, allc)}")
    print("\n".join(out))


if __name__ == "__main__":
    {"corpus": corpus, "lists": listing, "score": score}[sys.argv[1]](sys.argv[2])
