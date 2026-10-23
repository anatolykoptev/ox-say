# Changelog

## [0.1.26](https://github.com/anatolykoptev/ox-say/compare/v0.1.25...v0.1.26) (2026-10-23)


### Fixed

* **align:** free every ggml resource before exit — no Metal abort after a good run ([#203](https://github.com/anatolykoptev/ox-say/issues/203)) ([155d10c](https://github.com/anatolykoptev/ox-say/commit/155d10c5be86beaebaa102b74b321a37695be39d))


### Performance

* **engine:** ship precompiled Metal libraries — no shader compile at first run ([#206](https://github.com/anatolykoptev/ox-say/issues/206)) ([7fd3240](https://github.com/anatolykoptev/ox-say/commit/7fd3240230d3bb58c1f128dfafbdf69c19eb454f))

## [0.1.25](https://github.com/anatolykoptev/ox-say/compare/v0.1.24...v0.1.25) (2026-10-22)


### Added

* **dictation:** lower all sound while dictating — a choice next to pausing the music ([#199](https://github.com/anatolykoptev/ox-say/issues/199)) ([323726d](https://github.com/anatolykoptev/ox-say/commit/323726d348b375c83598c6ac80b90b44b7090704))

## [0.1.24](https://github.com/anatolykoptev/ox-say/compare/v0.1.23...v0.1.24) (2026-10-21)


### Added

* **dictation:** check for updates automatically and show them in the menu ([#197](https://github.com/anatolykoptev/ox-say/issues/197)) ([3f3162f](https://github.com/anatolykoptev/ox-say/commit/3f3162fcd1a29e7ec73ee5b9f726bf60b18728de))
* **dictation:** main window shell — Open OxSay, menu bar, activation policy ([#186](https://github.com/anatolykoptev/ox-say/issues/186)) ([f061bca](https://github.com/anatolykoptev/ox-say/commit/f061bcaf5f65cf14b63302ef8bb342bd981c1b3a))
* **dictation:** never lose a dictation — recent dictations, paste last, unread-paste notice ([#192](https://github.com/anatolykoptev/ox-say/issues/192)) ([110e281](https://github.com/anatolykoptev/ox-say/commit/110e281714d63a38959b049d8467c2b2033780b1))
* **dictation:** pause Music and Spotify while dictating ([#194](https://github.com/anatolykoptev/ox-say/issues/194)) ([cb1ba56](https://github.com/anatolykoptev/ox-say/commit/cb1ba56685c93366975b66f4c906cc522a60dd02))
* **produce:** per-phrase delivery op (style, pause) and job clone_mode ([#182](https://github.com/anatolykoptev/ox-say/issues/182)) ([ff420d1](https://github.com/anatolykoptev/ox-say/commit/ff420d174761f337d8ad7b76383d0d6140fbac9f))
* **produce:** per-phrase pace op (ffmpeg atempo) ([#184](https://github.com/anatolykoptev/ox-say/issues/184)) ([d913aeb](https://github.com/anatolykoptev/ox-say/commit/d913aeb2384acb605638e91a7b12601cb632984b))
* **say:** expand Russian numbers on the plain-speech routes ([#178](https://github.com/anatolykoptev/ox-say/issues/178)) ([c1c9ebc](https://github.com/anatolykoptev/ox-say/commit/c1c9ebc95fe25806698ad48403aa2fac4fe568e8))


### Fixed

* **dictation:** keep the dictation pill visible — owner-scoped clears, deterministic show, overlay logging ([#190](https://github.com/anatolykoptev/ox-say/issues/190)) ([8e96101](https://github.com/anatolykoptev/ox-say/commit/8e961018a259f6b04f2dcea60a78c344bc062f37))


### Performance

* **engine:** open the first STT session after idle without a fixed 500 ms wait ([#196](https://github.com/anatolykoptev/ox-say/issues/196)) ([f85fc06](https://github.com/anatolykoptev/ox-say/commit/f85fc06177785f2320cf90dca0286d5b1f65288e))

## [0.1.23](https://github.com/anatolykoptev/ox-say/compare/v0.1.22...v0.1.23) (2026-10-16)


### Added

* **config:** default the engine dir to the daemon's bundle Helpers ([#170](https://github.com/anatolykoptev/ox-say/issues/170)) ([7e43706](https://github.com/anatolykoptev/ox-say/commit/7e43706c667bfd7b57606c7ad5ebfa20de539573))
* **dictation:** app and service version handshake that waits for idle, stronger update check ([#176](https://github.com/anatolykoptev/ox-say/issues/176)) ([0b3f6ec](https://github.com/anatolykoptev/ox-say/commit/0b3f6ecd12f61b0d3e35cef918282e6a8ebd1d07))
* **dictation:** voiceover from Word, RTF, ODT and PDF, with a review sheet ([#173](https://github.com/anatolykoptev/ox-say/issues/173)) ([0767a87](https://github.com/anatolykoptev/ox-say/commit/0767a87062e5e9b9541ee318d527e2792e06919b))

## [0.1.22](https://github.com/anatolykoptev/ox-say/compare/v0.1.21...v0.1.22) (2026-10-15)


### Added

* **dictation:** tidy menu, Studio tools, About panel and app icon ([#167](https://github.com/anatolykoptev/ox-say/issues/167)) ([758001b](https://github.com/anatolykoptev/ox-say/commit/758001ba9ccd8f80c5a01541ae4565e9ce044446))

## [0.1.21](https://github.com/anatolykoptev/ox-say/compare/v0.1.20...v0.1.21) (2026-10-15)


### Added

* **daemon:** supervise the VoxCPM2 engine (audio.cpp) on Apple Silicon ([#138](https://github.com/anatolykoptev/ox-say/issues/138)) ([236dc76](https://github.com/anatolykoptev/ox-say/commit/236dc7689d0cfbfdc9d4f473fcd64db0d3566a16))
* **engine:** opt-in VoxCPM2 engine build and model fetch (Apple Silicon) ([#136](https://github.com/anatolykoptev/ox-say/issues/136)) ([5a121ff](https://github.com/anatolykoptev/ox-say/commit/5a121ff87391449679d20847fe2ef26826574d08))
* **mcp,cli:** expose VoxCPM2 knobs, voice design and voice updates to agents; document ([#161](https://github.com/anatolykoptev/ox-say/issues/161)) ([f662ff6](https://github.com/anatolykoptev/ox-say/commit/f662ff6edf427f06859909ac7667ddc3b0b42892))
* **produce:** CLI and MCP surfaces for long-form voiceover; document ([#164](https://github.com/anatolykoptev/ox-say/issues/164)) ([21c5346](https://github.com/anatolykoptev/ox-say/commit/21c53466c03057aeb29bbfc49b7ca025c063b9cc))
* **produce:** long-form voiceover jobs — one at a time, cancel, resume, chunk edits, dictation yield, battery pause ([#155](https://github.com/anatolykoptev/ox-say/issues/155)) ([561a540](https://github.com/anatolykoptev/ox-say/commit/561a540e5c4b7d6b433761ffe23c0dd128bb0611))
* **produce:** project manifest v1 and the streaming assembly of a voiceover ([#152](https://github.com/anatolykoptev/ox-say/issues/152)) ([3893cb5](https://github.com/anatolykoptev/ox-say/commit/3893cb5a9abcf14961204957ca1addac50dd19e6))
* **produce:** strict PCM I/O and the take core — render, cache and gate voiceover chunks ([#148](https://github.com/anatolykoptev/ox-say/issues/148)) ([2c0699d](https://github.com/anatolykoptev/ox-say/commit/2c0699df8210b91d130d9e9e17a141ff3c2f80a3))
* **tts:** loudness_lufs normalisation of a finished take ([#150](https://github.com/anatolykoptev/ox-say/issues/150)) ([08efad1](https://github.com/anatolykoptev/ox-say/commit/08efad1b423e4cc2cf919b5f36b5bc818228b904))
* **tts:** route speech to VoxCPM2 by model or voice (styles, clone modes, runaway guard) ([#142](https://github.com/anatolykoptev/ox-say/issues/142)) ([0ca67ac](https://github.com/anatolykoptev/ox-say/commit/0ca67ac40d617496b039de316e7ebfbadd1401b8))
* **voices:** design a voice from a description, keep the take you like ([#159](https://github.com/anatolykoptev/ox-say/issues/159)) ([caf946f](https://github.com/anatolykoptev/ox-say/commit/caf946fc4cb55033034d020b2b9896bd128dc77f))
* **voices:** per-voice engine, style and design origin; repairs keep them ([#140](https://github.com/anatolykoptev/ox-say/issues/140)) ([6fc6a11](https://github.com/anatolykoptev/ox-say/commit/6fc6a1184184f02691d21bbcacae7c07e811d46c))
* **vscript:** speak Russian numbers as words in long-form voiceover ([#163](https://github.com/anatolykoptev/ox-say/issues/163)) ([8f95f26](https://github.com/anatolykoptev/ox-say/commit/8f95f2604266f431542d9c0fc7043fe6c0c0e750))
* **vscript:** split voiceover scripts into chunks with pause and style markup ([#145](https://github.com/anatolykoptev/ox-say/issues/145)) ([a7cdf21](https://github.com/anatolykoptev/ox-say/commit/a7cdf21c791dc6a1a99646de7452b9b5ade1f688))
* **wordalign:** WER with ASR-slip and number tolerance, word timings and subtitle cues ([#144](https://github.com/anatolykoptev/ox-say/issues/144)) ([0f9cb0a](https://github.com/anatolykoptev/ox-say/commit/0f9cb0a338adc9acb5595c2441a64855ee1f11fd))


### Fixed

* **daemon:** set loudness with a constant gain and a true-peak limiter instead of loudnorm ([#166](https://github.com/anatolykoptev/ox-say/issues/166)) ([50d5b03](https://github.com/anatolykoptev/ox-say/commit/50d5b03f702b3d16cd2474e1a2bacfdc850ebb3e))
* **dictation:** never read or restore a Universal Clipboard copy ([#157](https://github.com/anatolykoptev/ox-say/issues/157)) ([ebb5361](https://github.com/anatolykoptev/ox-say/commit/ebb5361b8bed6dd9450943a9f0ce70bc49eb48b5))
* **dictation:** never report a failed update download as success ([#134](https://github.com/anatolykoptev/ox-say/issues/134)) ([8c544c2](https://github.com/anatolykoptev/ox-say/commit/8c544c24e2bfac6c6f89333ba0f8e5e86886114a)), closes [#132](https://github.com/anatolykoptev/ox-say/issues/132)
* **dictation:** show every update-check result and fix the hidden pill message ([#131](https://github.com/anatolykoptev/ox-say/issues/131)) ([5ff0bca](https://github.com/anatolykoptev/ox-say/commit/5ff0bcad11267ff95a1a20887dd5bed091f7fde7))

## [0.1.20](https://github.com/anatolykoptev/ox-say/compare/v0.1.19...v0.1.20) (2026-10-14)


### Fixed

* **dictation:** repair a stale Accessibility grant and log how text was delivered ([#128](https://github.com/anatolykoptev/ox-say/issues/128)) ([37ae2e2](https://github.com/anatolykoptev/ox-say/commit/37ae2e2512aae7c0132c63a3504e433edcddfc4e))
* **release:** retry stapler validate on transient network errors ([#126](https://github.com/anatolykoptev/ox-say/issues/126)) ([4f58ee0](https://github.com/anatolykoptev/ox-say/commit/4f58ee0be44489df8caa331920f4f1b2db969e96))

## [0.1.19](https://github.com/anatolykoptev/ox-say/compare/v0.1.18...v0.1.19) (2026-10-14)


### Fixed

* **voices:** keep a reference clip and its transcript describing the same audio ([#121](https://github.com/anatolykoptev/ox-say/issues/121)) ([353ad91](https://github.com/anatolykoptev/ox-say/commit/353ad91ceab752696ae8838745b55ef5e662763f))


### Documentation

* **performance:** add the Intel Mac measurements ([#119](https://github.com/anatolykoptev/ox-say/issues/119)) ([a3a2466](https://github.com/anatolykoptev/ox-say/commit/a3a246668b7b3e64083fbce38ef6ae183ad86469))

## [0.1.18](https://github.com/anatolykoptev/ox-say/compare/v0.1.17...v0.1.18) (2026-10-14)


### Added

* **bench:** measure the engines on Apple Silicon ([#114](https://github.com/anatolykoptev/ox-say/issues/114)) ([1d1cdf4](https://github.com/anatolykoptev/ox-say/commit/1d1cdf4da756a381b1c8735c303ef22d25c3fa54))
* **daemon:** share the GPU on unified memory (OX_SAY_GPU_MEMORY) ([#104](https://github.com/anatolykoptev/ox-say/issues/104)) ([aacee20](https://github.com/anatolykoptev/ox-say/commit/aacee20db2a58d678ab2f2818fc1a887841eff53))
* **engine:** build the engines natively for arm64 ([#105](https://github.com/anatolykoptev/ox-say/issues/105)) ([64bf3cf](https://github.com/anatolykoptev/ox-say/commit/64bf3cfd1d199a012ed87a6f871d027f3bdf46cf))
* **release:** package and install per architecture ([#110](https://github.com/anatolykoptev/ox-say/issues/110)) ([6220c64](https://github.com/anatolykoptev/ox-say/commit/6220c64bd3d12197f97324d038f648bf5d02abeb))


### Fixed

* install path — Homebrew PATH, macOS 13.3 floor, get.sh robustness ([#118](https://github.com/anatolykoptev/ox-say/issues/118)) ([9dc70da](https://github.com/anatolykoptev/ox-say/commit/9dc70da768cbd43f172f4a3a99b0054b7bd7aba7))


### Documentation

* describe ox-say on Apple Silicon and Intel ([#117](https://github.com/anatolykoptev/ox-say/issues/117)) ([59ea440](https://github.com/anatolykoptev/ox-say/commit/59ea44027db38e008dccfe429357012b1195d852))

## [0.1.17](https://github.com/anatolykoptev/ox-say/compare/v0.1.16...v0.1.17) (2026-10-10)


### Fixed

* **mcp:** back to stateless + go-mcpserver v0.21.0 (MCP 2026-07-28) ([#102](https://github.com/anatolykoptev/ox-say/issues/102)) ([4be6f08](https://github.com/anatolykoptev/ox-say/commit/4be6f08b0f244acfe59de0a2c94ff601a6886bac))

## [0.1.16](https://github.com/anatolykoptev/ox-say/compare/v0.1.15...v0.1.16) (2026-10-08)


### Fixed

* **mcp:** enable stateful sessions for standalone GET stream ([#100](https://github.com/anatolykoptev/ox-say/issues/100)) ([e2d67a7](https://github.com/anatolykoptev/ox-say/commit/e2d67a71e3934f7aac0be71a943b25eeace5c322))

## [0.1.15](https://github.com/anatolykoptev/ox-say/compare/v0.1.14...v0.1.15) (2026-10-04)


### Added

* per-language voice picks and a voice preview in the menu ([#98](https://github.com/anatolykoptev/ox-say/issues/98)) ([0b843f1](https://github.com/anatolykoptev/ox-say/commit/0b843f173865635fd1632200f028d8fd79f14ab2))

## [0.1.14](https://github.com/anatolykoptev/ox-say/compare/v0.1.13...v0.1.14) (2026-10-04)


### Added

* per-language default voices and an in-app update check ([#96](https://github.com/anatolykoptev/ox-say/issues/96)) ([c0e35d7](https://github.com/anatolykoptev/ox-say/commit/c0e35d7491f7f933d7cb738cbb3d9438d34ea3f4))

## [0.1.13](https://github.com/anatolykoptev/ox-say/compare/v0.1.12...v0.1.13) (2026-10-04)


### Added

* OX_SAY_VOICE pins the default speech voice ([#94](https://github.com/anatolykoptev/ox-say/issues/94)) ([d10f65c](https://github.com/anatolykoptev/ox-say/commit/d10f65c5e7eaf1a3df82f13b3ebe39ec31204783))

## [0.1.12](https://github.com/anatolykoptev/ox-say/compare/v0.1.11...v0.1.12) (2026-10-04)


### Added

* **dictation:** speak the selected text via a macOS service ([#92](https://github.com/anatolykoptev/ox-say/issues/92)) ([9d0e363](https://github.com/anatolykoptev/ox-say/commit/9d0e36386dcbbcbba9cfd98e1029d600932ade88))


### Documentation

* describe dictation streaming, its diagnostics and the STT pre-warm ([#89](https://github.com/anatolykoptev/ox-say/issues/89)) ([71c61fe](https://github.com/anatolykoptev/ox-say/commit/71c61fe873383c1127fb155d1ad6ccfd367ff4ab))

## [0.1.11](https://github.com/anatolykoptev/ox-say/compare/v0.1.10...v0.1.11) (2026-10-02)


### Added

* **stt:** default to the q8_0 Parakeet weights ([#86](https://github.com/anatolykoptev/ox-say/issues/86)) ([d92e5af](https://github.com/anatolykoptev/ox-say/commit/d92e5afb8872243b0a59b2f0a54bffc77e96a942))

## [0.1.10](https://github.com/anatolykoptev/ox-say/compare/v0.1.9...v0.1.10) (2026-10-01)


### Added

* **stt:** pre-warm a paged-out model when a session opens ([#82](https://github.com/anatolykoptev/ox-say/issues/82)) ([a27ca06](https://github.com/anatolykoptev/ox-say/commit/a27ca067ee1431741a22432f5ca7c8bbd003cebe))


### Fixed

* **install:** run the LaunchAgent as an Interactive job ([#84](https://github.com/anatolykoptev/ox-say/issues/84)) ([5a37f0a](https://github.com/anatolykoptev/ox-say/commit/5a37f0a4c5be0fb531965ecde0bb56601364043f))

## [0.1.9](https://github.com/anatolykoptev/ox-say/compare/v0.1.8...v0.1.9) (2026-10-01)


### Added

* **dictation:** log one timing line per dictation, without text ([#80](https://github.com/anatolykoptev/ox-say/issues/80)) ([1163379](https://github.com/anatolykoptev/ox-say/commit/11633790c394a865503deb106b4bbc825f30c576))
* **stt:** report why each session segment was cut ([#79](https://github.com/anatolykoptev/ox-say/issues/79)) ([12ee6b6](https://github.com/anatolykoptev/ox-say/commit/12ee6b6adb89c752c14e2a474babacc84a5ffff0))

## [0.1.8](https://github.com/anatolykoptev/ox-say/compare/v0.1.7...v0.1.8) (2026-10-01)


### Fixed

* **daemon:** arbitrate the GPU both ways with a shared lease ([#76](https://github.com/anatolykoptev/ox-say/issues/76)) ([513a090](https://github.com/anatolykoptev/ox-say/commit/513a0903f0d892348c9e3d2b424149ed5cd28462))

## [0.1.7](https://github.com/anatolykoptev/ox-say/compare/v0.1.6...v0.1.7) (2026-10-01)


### Fixed

* **daemon:** hold the engine guard across AddVoice normalization ([#69](https://github.com/anatolykoptev/ox-say/issues/69)) ([98aa2e9](https://github.com/anatolykoptev/ox-say/commit/98aa2e9c4e66bf9c8c83dbf282f746e0764c57e3))
* **daemon:** keepalive for long tool calls; bound the STT seconds ([#74](https://github.com/anatolykoptev/ox-say/issues/74)) ([53f130c](https://github.com/anatolykoptev/ox-say/commit/53f130c272259131fbfcf188258d78a9a3f930b4))
* **engine:** deliver the start error to callers that overlapped the attempt ([#66](https://github.com/anatolykoptev/ox-say/issues/66)) ([b65488c](https://github.com/anatolykoptev/ox-say/commit/b65488c8381ea3e1fd9e6a974638447e5c22d240))
* **engine:** gate LiveURL on stopping children; validate AddVoice before the guard ([#70](https://github.com/anatolykoptev/ox-say/issues/70), [#67](https://github.com/anatolykoptev/ox-say/issues/67)) ([#75](https://github.com/anatolykoptev/ox-say/issues/75)) ([ebbe828](https://github.com/anatolykoptev/ox-say/commit/ebbe8286200d092398442a4003427686667356b4))
* **engine:** reap an orphan only when its start time matches the pidfile ([#72](https://github.com/anatolykoptev/ox-say/issues/72)) ([f9eecab](https://github.com/anatolykoptev/ox-say/commit/f9eecab3e541226bfb8027f2539e9dacbcff8cf6))

## [0.1.6](https://github.com/anatolykoptev/ox-say/compare/v0.1.5...v0.1.6) (2026-10-01)


### Fixed

* **dictation:** layout-aware ⌘V; clipboard snapshot keeps order, skips promises ([#57](https://github.com/anatolykoptev/ox-say/issues/57)) ([f3d8911](https://github.com/anatolykoptev/ox-say/commit/f3d891163701e08e549c87d06cc9afbe6c1f0df8))
* **dictation:** refresh the shortcut menu on every open, scope the ended reason ([#59](https://github.com/anatolykoptev/ox-say/issues/59)) ([f2e8ba0](https://github.com/anatolykoptev/ox-say/commit/f2e8ba066663a2e9dbf7657b2683340de8012348))
* **engine:** close unframed-body and content-type gaps in local HTTP servers ([#60](https://github.com/anatolykoptev/ox-say/issues/60)) ([562ce19](https://github.com/anatolykoptev/ox-say/commit/562ce19414cc6f07aa70a8ac3d9d1ac277783df8)), closes [#40](https://github.com/anatolykoptev/ox-say/issues/40)
* **engine:** ox-align -ng skips Metal; build fails if the switch disappears ([#54](https://github.com/anatolykoptev/ox-say/issues/54)) ([7e77569](https://github.com/anatolykoptev/ox-say/commit/7e77569d3336f01383087342c05f22b228b973f4)), closes [#50](https://github.com/anatolykoptev/ox-say/issues/50) [#53](https://github.com/anatolykoptev/ox-say/issues/53) [#41](https://github.com/anatolykoptev/ox-say/issues/41)
* **stt:** scale the transcription timeout with audio duration ([#61](https://github.com/anatolykoptev/ox-say/issues/61)) ([072f2c5](https://github.com/anatolykoptev/ox-say/commit/072f2c590be80316af20daffcc097f0deea5be45))

## [0.1.5](https://github.com/anatolykoptev/ox-say/compare/v0.1.4...v0.1.5) (2026-10-01)


### Fixed

* **daemon:** cap the daemon log and drop per-chunk access lines ([#48](https://github.com/anatolykoptev/ox-say/issues/48)) ([7ba4455](https://github.com/anatolykoptev/ox-say/commit/7ba44559f3facf3901206b8127e9c4895ee42cfd)), closes [#9](https://github.com/anatolykoptev/ox-say/issues/9)
* **dictation:** tag feed chunks with the dictation generation ([#51](https://github.com/anatolykoptev/ox-say/issues/51)) ([ee89b91](https://github.com/anatolykoptev/ox-say/commit/ee89b917b155cb9718f76b7041580d8c0aaea45c))
* **stt:** -ng skips Metal entirely, ~50 s off a fresh binary's start ([#49](https://github.com/anatolykoptev/ox-say/issues/49)) ([2bc396f](https://github.com/anatolykoptev/ox-say/commit/2bc396f7a08a589d1ff23e1438d37efa44997ea3))

## [0.1.4](https://github.com/anatolykoptev/ox-say/compare/v0.1.3...v0.1.4) (2026-09-30)


### Added

* **dictation:** stream the recording into a transcription session ([#45](https://github.com/anatolykoptev/ox-say/issues/45)) ([898a09c](https://github.com/anatolykoptev/ox-say/commit/898a09c31e4dd2d728d5b83a2574005f9970da4a))

## [0.1.3](https://github.com/anatolykoptev/ox-say/compare/v0.1.2...v0.1.3) (2026-09-30)


### Added

* **stt:** proxy streaming transcription sessions on the resident server ([#43](https://github.com/anatolykoptev/ox-say/issues/43)) ([21d4c12](https://github.com/anatolykoptev/ox-say/commit/21d4c1292db1f569efddccbf043183d6e1f4d600))
* **stt:** VAD-segmented streaming transcription sessions in ox-stt --serve ([#42](https://github.com/anatolykoptev/ox-say/issues/42)) ([52b4ebf](https://github.com/anatolykoptev/ox-say/commit/52b4ebf95bb02596e1abb6d91ac2dfecedd827db))

## [0.1.2](https://github.com/anatolykoptev/ox-say/compare/v0.1.1...v0.1.2) (2026-09-30)


### Added

* **stt:** ox-stt --serve keeps the Parakeet model resident ([#34](https://github.com/anatolykoptev/ox-say/issues/34)) ([43f4971](https://github.com/anatolykoptev/ox-say/commit/43f49718997cc231e7bfda8e0d7f1ca7e25f841e))
* **stt:** resident CPU speech-to-text server with CLI fallback ([#36](https://github.com/anatolykoptev/ox-say/issues/36)) ([148f1ae](https://github.com/anatolykoptev/ox-say/commit/148f1aebae0c5132bfceb5f63e5e1eca7c96e698))

## [0.1.1](https://github.com/anatolykoptev/ox-say/compare/v0.1.0...v0.1.1) (2026-09-30)


### Added

* ship the dictation app in releases ([#26](https://github.com/anatolykoptev/ox-say/issues/26)) ([bf22aae](https://github.com/anatolykoptev/ox-say/commit/bf22aae1cb293afff4caf4c6214491d081fbe61f))
* sign and notarize the dictation app in releases ([#31](https://github.com/anatolykoptev/ox-say/issues/31)) ([b5bb0e6](https://github.com/anatolykoptev/ox-say/commit/b5bb0e6da7961e7f4aacd5fa4bdc51ea96d9880e))


### Fixed

* **dictation:** a slow first transcription no longer looks like a hang ([#33](https://github.com/anatolykoptev/ox-say/issues/33)) ([58068e9](https://github.com/anatolykoptev/ox-say/commit/58068e9642741627aed97bbfc000bdf3389b41b5))

## 0.1.0 (2026-09-30)


### Added

* **align:** ox-align wav2vec2 CTC emissions on ggml ([#12](https://github.com/anatolykoptev/ox-say/issues/12)) ([94e33a1](https://github.com/anatolykoptev/ox-say/commit/94e33a16dcd44d35be6c0eb3e117c864cc1b3bd0))
* **dictation:** menu-bar app that types what you say ([#19](https://github.com/anatolykoptev/ox-say/issues/19)) ([efb3275](https://github.com/anatolykoptev/ox-say/commit/efb3275f65e5e12d4c1fec12e1b5178684da1994))
* **engine:** MPS matrix multiply on discrete AMD GPUs ([#3](https://github.com/anatolykoptev/ox-say/issues/3)) ([f06c0b1](https://github.com/anatolykoptev/ox-say/commit/f06c0b18968639f3f23ef1b77f25315a9fe8a874))
* **engine:** pinned qwentts.cpp build for Intel Macs with AMD GPUs ([55ab979](https://github.com/anatolykoptev/ox-say/commit/55ab97965b2b8ec10f97eb733a133adfcc2cc601))
* **install:** LaunchAgent and install/uninstall scripts ([#8](https://github.com/anatolykoptev/ox-say/issues/8)) ([3cbe998](https://github.com/anatolykoptev/ox-say/commit/3cbe9985255f8528c541c53159f73b941d3e2a11))
* one-command install from prebuilt releases ([#18](https://github.com/anatolykoptev/ox-say/issues/18)) ([500e83b](https://github.com/anatolykoptev/ox-say/commit/500e83bc6e1210f910932e42e3fbfef9f54b725f))
* ox-say daemon, CLI and MCP server ([#2](https://github.com/anatolykoptev/ox-say/issues/2)) ([d07b0e0](https://github.com/anatolykoptev/ox-say/commit/d07b0e071986f47110457ca06b9e401c0e09a3c7))
* speech-to-text in the daemon (HTTP, MCP, CLI) ([#10](https://github.com/anatolykoptev/ox-say/issues/10)) ([7e19697](https://github.com/anatolykoptev/ox-say/commit/7e196976ea27de044d5f86d377c2c2d110bc250b))
* **stt:** ox-stt speech-to-text engine (Parakeet TDT, Whisper) ([#4](https://github.com/anatolykoptev/ox-say/issues/4)) ([96de1bb](https://github.com/anatolykoptev/ox-say/commit/96de1bbe8c315a7c30b1e87916ec4d760c85a6c6))


### Fixed

* **engine:** make the MPS mul_mat path opt-in ([#15](https://github.com/anatolykoptev/ox-say/issues/15)) ([43f2767](https://github.com/anatolykoptev/ox-say/commit/43f27676233ea08533d6aeb101fe55d4861edad8))
* **engine:** make tts-server local-only ([#5](https://github.com/anatolykoptev/ox-say/issues/5)) ([7f823a1](https://github.com/anatolykoptev/ox-say/commit/7f823a1a88cdf361d6ed52f95756377337bf7f0f))
