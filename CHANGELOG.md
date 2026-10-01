# Changelog

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
