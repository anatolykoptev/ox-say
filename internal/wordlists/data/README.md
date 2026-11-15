# Word lists

Used by `internal/wordlists` to keep ordinary words out of the decoder boost list: a Cyrillic form is checked
against the Russian dictionary, a Latin form against the English one. Not used for anything else; never sent
anywhere. Both come from [wooorm/dictionaries](https://github.com/wooorm/dictionaries) (`dictionaries/ru` and
`dictionaries/en`, last change to both at commit `836d7c2032167880e639a1fe522748733e528c2d`, 2023-11-03), the
`.dic` gzipped and otherwise byte-identical.

## Russian: `ru.aff`, `ru.dic.gz`, `LICENSE.ru`
Alexander I. Lebedev's Russian dictionary (1997-2008), npm `dictionary-ru` 3.0.0, BSD-3-Clause style (modified
versions must be marked as such).
- `ru.aff` sha256 `38ce7d4af78e211e9bafe4bf7e3d6a2c420591136cb738ec6648f8fdf6524cd7`
- `index.dic` (uncompressed) sha256 `f6047416a0204adbecf3a451b874ec8a97ee37e2cbc714466ef04d8dbcc0d6fc`

## English: `en.aff`, `en.dic.gz`, `LICENSE.en`
The en_US Hunspell dictionary generated from SCOWL (Kevin Atkinson, 2020.12.07), npm `dictionary-en` 4.0.0,
licence `(MIT AND BSD)`: SCOWL's permissive notice (use, copy, modify, distribute and sell for any purpose) plus
Ispell's BSD licence, text in `LICENSE.en`.
- `en.aff` sha256 `8ae1f19d4840d957728ad90555d5a8dff6cc5c046279c95ff0c00fc0a0136c7b`
- `index.dic` (uncompressed) sha256 `f0b1a234bd178bdd01875b2a392a9647f888b8fe879f79c52aae62c2759b3647`
