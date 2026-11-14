# Russian word list

`ru.aff` and `ru.dic.gz` (the `.dic` gzipped, otherwise byte-identical) are the Russian Hunspell dictionary
of Alexander I. Lebedev, as packaged by [wooorm/dictionaries](https://github.com/wooorm/dictionaries)
(`dictionaries/ru`, npm `dictionary-ru` 3.0.0, last change to the directory: commit
`836d7c2032167880e639a1fe522748733e528c2d`, 2023-11-03).

- Licence: BSD-3-Clause style, text in `LICENSE` (copyright 1997-2008 Alexander I. Lebedev; modified versions must
  be marked as such). This copy is unmodified apart from gzip on the `.dic`.
- `ru.aff` sha256 `38ce7d4af78e211e9bafe4bf7e3d6a2c420591136cb738ec6648f8fdf6524cd7`
- uncompressed `index.dic` sha256 `f6047416a0204adbecf3a451b874ec8a97ee37e2cbc714466ef04d8dbcc0d6fc`
  (146,268 stems with affix flags; the affix rules expand them to every inflection).

Used by `internal/ruwords` to keep ordinary Russian words out of the decoder boost list. Not used for
anything else; never sent anywhere.
