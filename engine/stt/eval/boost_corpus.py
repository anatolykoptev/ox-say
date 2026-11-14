"""Build the term-boost eval corpus manifest: <out>/manifest.tsv, one clip per line.

    python3 -I boost_corpus.py <vocab.json> <out-dir> <repo-root>

Columns: id, kind (term|nearmiss|noterm), lang (ru|en), voice, text, terms (expected terms, "|"-joined).
Everything is derived from fixed lists and a fixed seed (SEED), so the manifest is reproducible. Near-miss
sentences are derived mechanically: English words whose canonical BPE segmentation shares the first two
pieces of a term's, and Russian whole-word pieces of the vocabulary that share the first three letters
of a term's Russian pronunciation. vocab.json comes from parakeet_vocab.py.
"""
import json
import os
import random
import re
import sys

SEED = 20261114
TERMS = ["OxSay", "Hormozi", "Devin", "GitHub", "vaelor", "Dropbox", "Sonnet", "Haiku", "Fable", "Codex",
         "krolik", "pillow", "kisol", "dozor", "Glossa", "Claude", "Parakeet", "Brave", "Opus", "Hugging Face"]
# how a Russian speaker would say each term; used only to pick Russian near-miss words
RU_SAY = {"OxSay": "оксей", "Hormozi": "хормози", "Devin": "дэвин", "GitHub": "гитхаб", "vaelor": "вейлор",
          "Dropbox": "дропбокс", "Sonnet": "соннет", "Haiku": "хайку", "Fable": "фейбл", "Codex": "кодекс",
          "krolik": "кролик", "pillow": "пиллоу", "kisol": "кисол", "dozor": "дозор", "Glossa": "глосса",
          "Claude": "клод", "Parakeet": "паракит", "Brave": "брейв", "Opus": "опус", "Hugging Face": "хагинг фейс"}
RU_VOICES = ["ru-milena", "ru-ruslan"]
EN_VOICE = "en-emma"
RU_T = ["Я вчера читал про {T} и остался доволен.",
        "Самое важное на сегодня, это {T}.",
        "{T} уже работает, можешь проверить."]
EN_T = ["I was reading about {T} yesterday and I liked it.",
        "The most important thing today is {T}.",
        "{T} is already working, you can check it."]
RU_S = ["Мы", "Они", "Моя сестра", "Наш сосед", "Сегодня утром я", "Вчера вечером мы"]
RU_V = ["купили", "обсудили", "посмотрели", "забыли", "нашли", "забронировали"]
RU_O = ["новый диван для гостиной", "расписание поездов на пятницу", "старые фотографии из отпуска",
        "билеты на концерт в субботу", "рецепт яблочного пирога", "маршрут до загородного дома"]
EN_S = ["We", "They", "My sister", "Our neighbour", "This morning I", "Last night we"]
EN_V = ["bought", "discussed", "watched", "forgot", "found", "booked"]
EN_O = ["a new sofa for the living room", "the train schedule for Friday", "old photos from the holiday",
        "tickets for the concert on Saturday", "a recipe for apple pie", "the route to the country house"]
RU_NEAR_T = "Он сказал слово {W} три раза подряд."
EN_NEAR_T = ["She said the word {W} twice during the lesson.", "I saw {W} written on the sign."]


_IDS = {}


def canonical_bpe(pieces, word):
    """Merge by lowest piece id (the same rule as boost.h); [] when a character has no piece."""
    if not _IDS:
        for i, p in enumerate(pieces):
            _IDS.setdefault(p, i)
    ids = _IDS
    sym = ["▁"] + list(word)
    if any(s not in ids for s in sym):
        return []
    while True:
        best, at = None, 0
        for i in range(len(sym) - 1):
            j = ids.get(sym[i] + sym[i + 1])
            if j is not None and (best is None or j < best):
                best, at = j, i
        if best is None:
            return sym
        sym[at:at + 2] = [sym[at] + sym[at + 1]]


def main(vocab_path, out, repo):
    pieces = json.load(open(vocab_path, encoding="utf-8"))
    rng = random.Random(SEED)
    rows = []

    def add(kind, lang, voice, text, terms):
        rows.append((f"{kind[:2]}{len(rows):03d}", kind, lang, voice, text, "|".join(terms)))

    for t in TERMS:
        for tpl in RU_T:
            for v in RU_VOICES:
                add("term", "ru", v, tpl.format(T=t), [t])
        for tpl in EN_T:
            add("term", "en", EN_VOICE, tpl.format(T=t), [t])

    def combos(S, V, O, n):
        allc = [f"{s} {v} {o}." for s in S for v in V for o in O]
        rng.shuffle(allc)
        return allc[:n]

    for i, s in enumerate(combos(RU_S, RU_V, RU_O, 30)):
        add("noterm", "ru", RU_VOICES[i % 2], s, [])
    for s in combos(EN_S, EN_V, EN_O, 30):
        add("noterm", "en", EN_VOICE, s, [])

    # English near-miss: dictionary words sharing the term's first two canonical pieces (case folded)
    words = [w.strip() for w in open("/usr/share/dict/words", encoding="utf-8", errors="ignore")]
    words = sorted({w for w in words if w.isalpha() and w.isascii() and w.islower() and 4 <= len(w) <= 9})
    en_pool = []
    for t in TERMS:
        tp = [p.lstrip("▁").lower() for p in canonical_bpe(pieces, t.split()[0])]
        head = tp[:2]
        hits = []
        for w in words:
            if w == t.lower():
                continue
            wp = [p.lstrip("▁") for p in canonical_bpe(pieces, w)]
            if len(wp) >= 2 and wp[:2] == head:
                hits.append(w)
        if len(hits) < 3 and len(head[0]) >= 3:  # too few: words sharing just the first piece (3+ letters)
            for w in words:
                wp = [p.lstrip("▁") for p in canonical_bpe(pieces, w)]
                if w != t.lower() and wp and wp[0] == head[0] and w not in hits:
                    hits.append(w)
        rng.shuffle(hits)
        en_pool.append((t, hits[:3]))
    en_words = [(t, w) for t, hs in en_pool for w in hs]
    rng.shuffle(en_words)
    for i, (t, w) in enumerate(en_words[:30]):
        add("nearmiss", "en", EN_VOICE, EN_NEAR_T[i % 2].format(W=w), [])
    # Russian near-miss: whole-word Cyrillic pieces sharing the first three letters of the Russian saying
    # real Russian words only: the repo's own Russian text, at least 5 letters
    seen = set()
    for dp, dn, fn in os.walk(repo):
        dn[:] = [d for d in dn if d not in (".git", "build", "node_modules")]
        for f in fn:
            if f.endswith((".go", ".swift", ".md", ".json", ".txt", ".html", ".sh", ".yml")):
                try:
                    txt = open(os.path.join(dp, f), encoding="utf-8").read()
                except (OSError, UnicodeDecodeError):
                    continue
                seen.update(w.lower() for w in re.findall(r"[А-Яа-яЁё]{4,12}", txt))
    cyr = sorted(w for w in seen if len(w) >= 5)
    ru_pool = []
    for t in TERMS:
        pre = RU_SAY[t].split()[0][:2]
        hits = [w for w in cyr if w.startswith(pre) and w != RU_SAY[t]]
        rng.shuffle(hits)
        ru_pool += [(t, w) for w in hits[:2]]
    rng.shuffle(ru_pool)
    for t, w in ru_pool[:10]:
        add("nearmiss", "ru", "ru-milena", RU_NEAR_T.format(W=w), [])

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "manifest.tsv"), "w", encoding="utf-8") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    from collections import Counter
    print(Counter((r[1], r[2]) for r in rows), len(rows), "clips; en near-miss pool", len(en_words),
          "ru near-miss pool", len(ru_pool))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
