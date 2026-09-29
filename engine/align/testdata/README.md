# Test audio provenance

Both clips are LibriSpeech **test-clean** material, fetched as FLAC via
huggingface.co/datasets/Narsil/asr_dummy (files `1.flac`, `2.flac`,
`3.flac`), which repacks the OpenSLR test-clean set. LibriSpeech is
CC-BY-4.0, (c) 2014 Vassil Panayotov & Daniel Povey —
https://www.openslr.org/12.

- `clip-short.wav` (10.435 s) = utterance `1089-134686-0000`
  ("he hoped there would be stew for dinner, turnips and carrots and
  bruised potatoes and fat mutton pieces to be ladled out in thick,
  peppered, flour-fattened sauce"), resampled to 16 kHz mono PCM16.
- `clip-long.wav` (70 s exactly) exercises the multi-window path:
  `1089-134686-0000`, `1089-134686-0001` ("stuff it into you, his belly
  counselled him"), `1089-134686-0002` ("after early nightfall the yellow
  lamps would light up, here and there, the squalid quarter of the
  brothels") concatenated end to end and the stream repeated until the
  70-second mark, then converted to 16 kHz mono PCM16.

Identification is by transcript: the dataset loader numbers the files 0-3
and does not carry the LibriSpeech utterance ids; the texts above are the
LibriSpeech test-clean transcription entries for those utterance ids.
