# Changelog

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
