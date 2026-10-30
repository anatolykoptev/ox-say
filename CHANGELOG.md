# Changelog

## [0.1.30](https://github.com/anatolykoptev/ox-say/compare/v0.1.29...v0.1.30) (2026-10-30)


### Documentation

* **readme:** bring the README up to v0.1.29 (meetings, installer, Intel figures, re-decode, licences) ([#391](https://github.com/anatolykoptev/ox-say/issues/391)) ([63382d1](https://github.com/anatolykoptev/ox-say/commit/63382d1cb006fda5843a277f6e174311b49a82cd))

## [0.1.29](https://github.com/anatolykoptev/ox-say/compare/v0.1.28...v0.1.29) (2026-10-30)


### Added

* **app:** main window wired to meetings, settings and dictation data ([#269](https://github.com/anatolykoptev/ox-say/issues/269)) ([11a4711](https://github.com/anatolykoptev/ox-say/commit/11a47113d0a1fc1935154180e3805dad04fd1dbd))
* **app:** name, merge and split meeting speakers; say why there are none ([#259](https://github.com/anatolykoptev/ox-say/issues/259)) ([c459f38](https://github.com/anatolykoptev/ox-say/commit/c459f3880bb6337be6874573bf56a7c9c9655209))
* **app:** read the selection in Chromium/Electron apps over AX before falling back to copy ([#220](https://github.com/anatolykoptev/ox-say/issues/220)) ([#365](https://github.com/anatolykoptev/ox-say/issues/365)) ([5a3b05e](https://github.com/anatolykoptev/ox-say/commit/5a3b05ed3c6a706f22fe2cea2796af2e29c727a6))
* **app:** search meetings, find in a transcript, play from a line ([#271](https://github.com/anatolykoptev/ox-say/issues/271)) ([2762a63](https://github.com/anatolykoptev/ox-say/commit/2762a6339b2fa5e86d541d0300ab20320a1d2ae3))
* **config:** notes engine settings (ox-llm binary, model, port, idle stop) ([#242](https://github.com/anatolykoptev/ox-say/issues/242)) ([4b9c28c](https://github.com/anatolykoptev/ox-say/commit/4b9c28c91ff8703f7e314b4db0797904c22713a0))
* **daemon:** meeting HTTP routes and MCP tools ([#250](https://github.com/anatolykoptev/ox-say/issues/250)) ([4e69781](https://github.com/anatolykoptev/ox-say/commit/4e6978133c8623e1986aafe906e78a67a778d4af))
* **daemon:** meeting search, title rename, mixed audio stream ([#267](https://github.com/anatolykoptev/ox-say/issues/267)) ([b01d379](https://github.com/anatolykoptev/ox-say/commit/b01d3790dce8611ae2758ed31281f225cce1bbcd))
* **daemon:** notes engine supervisor, meeting runner and model download ([#246](https://github.com/anatolykoptev/ox-say/issues/246)) ([cd8439e](https://github.com/anatolykoptev/ox-say/commit/cd8439ed44bbbd5a3b90141c27938c498883ee30))
* **daemon:** run ox-diar for meeting voices; speakers over HTTP and MCP ([#257](https://github.com/anatolykoptev/ox-say/issues/257)) ([78f8ac3](https://github.com/anatolykoptev/ox-say/commit/78f8ac3d55d45d8a8a756b4f0287fa2abfde1c45))
* **dictation:** call detection and the meeting auto start/stop debounce ([#234](https://github.com/anatolykoptev/ox-say/issues/234)) ([1548a65](https://github.com/anatolykoptev/ox-say/commit/1548a651f120a491ae608bd308ae178f1c110dc7))
* **dictation:** call watcher, recording badge, notifier and 16 kHz converter ([#248](https://github.com/anatolykoptev/ox-say/issues/248)) ([564ec2d](https://github.com/anatolykoptev/ox-say/commit/564ec2d68d41df5bf0b067d4fdaf665d19408451))
* **dictation:** Lower All Sound is the default sound mode ([#264](https://github.com/anatolykoptev/ox-say/issues/264)) ([d8813cc](https://github.com/anatolykoptev/ox-say/commit/d8813ccb1499318c774d1a5effa319aca4b1f3e5))
* **dictation:** meeting menu, notes export, channel writer and recording-is-work ([#245](https://github.com/anatolykoptev/ox-say/issues/245)) ([545d1eb](https://github.com/anatolykoptev/ox-say/commit/545d1ebba911707e9cc2320c4d5ccf6b4edc9dc7))
* **dictation:** meeting models, daemon status notes block and client calls ([#231](https://github.com/anatolykoptev/ox-say/issues/231)) ([3000f37](https://github.com/anatolykoptev/ox-say/commit/3000f377050cf3ea4365af579ed1bc49b54ee767))
* **dictation:** meeting settings and localized strings ([#226](https://github.com/anatolykoptev/ox-say/issues/226)) ([5f34771](https://github.com/anatolykoptev/ox-say/commit/5f3477124182bbb3867d2cba323d1aecb5b2a1d9))
* **dictation:** permission prompt text for system audio recording and the browser tab ([#240](https://github.com/anatolykoptev/ox-say/issues/240)) ([c449d1f](https://github.com/anatolykoptev/ox-say/commit/c449d1f15ac4e73029435aa63afaf905c94972af))
* **dictation:** record a meeting from the menu (two channels, transcript, notes) ([#261](https://github.com/anatolykoptev/ox-say/issues/261)) ([2e38587](https://github.com/anatolykoptev/ox-say/commit/2e38587c312450355072af1d3b2bdfd0e28eeed3))
* **engine:** ox-diar, far-side speaker diarization on FluidAudio ([#253](https://github.com/anatolykoptev/ox-say/issues/253)) ([da641f5](https://github.com/anatolykoptev/ox-say/commit/da641f5678f533ebf78d2029364988a06ddf40ff))
* **engine:** ox-llm (llama.cpp llama-server) in the engine build, installer and package ([#230](https://github.com/anatolykoptev/ox-say/issues/230)) ([182f37d](https://github.com/anatolykoptev/ox-say/commit/182f37d0e894fe543d9107ecf1e5c31a7b6bd648))
* **engine:** precompiled Metal library for ox-llm ([#236](https://github.com/anatolykoptev/ox-say/issues/236)) ([e6c3edb](https://github.com/anatolykoptev/ox-say/commit/e6c3edb465d146a2291b7ddd9a2576b9c6d27946))
* **engine:** re-decode cut streamed sessions at /finish for short dictations ([#88](https://github.com/anatolykoptev/ox-say/issues/88)) ([#377](https://github.com/anatolykoptev/ox-say/issues/377)) ([990c9ea](https://github.com/anatolykoptev/ox-say/commit/990c9eaf8c96c2484f84a8451d85ed87e8f7de77))
* **meeting:** ask before recording a call that may be gone; ask before voices Try Again remakes names and notes ([#373](https://github.com/anatolykoptev/ox-say/issues/373)) ([2dc96d8](https://github.com/anatolykoptev/ox-say/commit/2dc96d8da7f9171d19e9941ae9e4c6b49ffcb3f5))
* **meeting:** far-side voices, the speaker rule, renames and voices retry ([#254](https://github.com/anatolykoptev/ox-say/issues/254)) ([0cb2a57](https://github.com/anatolykoptev/ox-say/commit/0cb2a57ca17716b23b41829ea3aeb775bebc9bbb))
* **meeting:** meeting store, channel merge and the speakers echo gate ([#228](https://github.com/anatolykoptev/ox-say/issues/228)) ([adac0f9](https://github.com/anatolykoptev/ox-say/commit/adac0f97e4a545f60c1bbeaa4da7baf2fbd53c52))
* **meeting:** meetings on by default, asking "Record this call?"; Ask / Record automatically / Off ([#341](https://github.com/anatolykoptev/ox-say/issues/341)) ([2d3b03e](https://github.com/anatolykoptev/ox-say/commit/2d3b03e15111cac89b036b50243d1b68944ab2a1))
* **meeting:** per-chunk structured notes with dedupe in code ([#233](https://github.com/anatolykoptev/ox-say/issues/233)) ([ed62147](https://github.com/anatolykoptev/ox-say/commit/ed621473710e7b53fc3bb61c549b30eebc9cb5e3))
* **meeting:** resumable transcription and notes runner, audio retention ([#239](https://github.com/anatolykoptev/ox-say/issues/239)) ([6d60377](https://github.com/anatolykoptev/ox-say/commit/6d60377c8076073516d3aa07a519cd772d4a5a29))
* **meetings:** say why a meeting, its notes or the model download failed, in en and ru ([#288](https://github.com/anatolykoptev/ox-say/issues/288)) ([dc72933](https://github.com/anatolykoptev/ox-say/commit/dc729337f65bc9bb71d81332584462081392a275))
* **meeting:** voices Try Again once diarization becomes available ([#339](https://github.com/anatolykoptev/ox-say/issues/339)) ([ce0c8db](https://github.com/anatolykoptev/ox-say/commit/ce0c8dbd5098620f634d5f228953bc9fdcb018fa))
* **models:** fetch-models --notes-only for the meeting-notes model ([#224](https://github.com/anatolykoptev/ox-say/issues/224)) ([caf44f5](https://github.com/anatolykoptev/ox-say/commit/caf44f5747c70b4ad2528ed754044d1ad3a5fdb4))
* **voices,pcm:** word-share and quietest-window helpers for meeting transcription ([#223](https://github.com/anatolykoptev/ox-say/issues/223)) ([634f96b](https://github.com/anatolykoptev/ox-say/commit/634f96b6d78daf3c6ff8df84eb34b99b084f7ac4))


### Fixed

* **app,daemon:** double-runaway sentence, big CP1251 guessed on a sample, linear PDF join, tap recovery in Core; curl 23 not disk_full ([#354](https://github.com/anatolykoptev/ox-say/issues/354)) ([2f6f155](https://github.com/anatolykoptev/ox-say/commit/2f6f155f588c639327005aeafab22b1f1f482f31))
* **app,daemon:** failed voices kind served as voices_retryable; synthetic ⌘V/⌘C carry their letter ([#340](https://github.com/anatolykoptev/ox-say/issues/340), [#58](https://github.com/anatolykoptev/ox-say/issues/58)) ([#352](https://github.com/anatolykoptev/ox-say/issues/352)) ([4d5d177](https://github.com/anatolykoptev/ox-say/commit/4d5d177da5f98e5d8892dcecb8d310bdad556c7d))
* **app,installer:** the installer run has a ceiling and kills its whole tree; self-test calls are bounded ([#357](https://github.com/anatolykoptev/ox-say/issues/357)) ([3f3f47b](https://github.com/anatolykoptev/ox-say/commit/3f3f47bbdb0bbf4903ae038f62879125ceb604dc))
* **app:** dictation and speak errors in the user's language; the literal guard sees error text at a sink ([#351](https://github.com/anatolykoptev/ox-say/issues/351)) ([d943358](https://github.com/anatolykoptev/ox-say/commit/d9433585d4da5fd281d5c17f7d98202eedd816d0))
* **app:** duplicate speaker names, save/badge seams, follow-ups of [#383](https://github.com/anatolykoptev/ox-say/issues/383) ([#387](https://github.com/anatolykoptev/ox-say/issues/387)) ([3316831](https://github.com/anatolykoptev/ox-say/commit/3316831e8805f24c3439816cee50e866856a240d))
* **app:** follow-ups of [#371](https://github.com/anatolykoptev/ox-say/issues/371) [#372](https://github.com/anatolykoptev/ox-say/issues/372) [#374](https://github.com/anatolykoptev/ox-say/issues/374) ([#383](https://github.com/anatolykoptev/ox-say/issues/383)) ([08177e0](https://github.com/anatolykoptev/ox-say/commit/08177e05c31b6cecb934f3225d7b99dacfc66f42))
* **app:** localized notices, late live text gate, per-device duck records, bounded clipboard read, Swift 6 warnings ([#312](https://github.com/anatolykoptev/ox-say/issues/312)) ([fad1caa](https://github.com/anatolykoptev/ox-say/commit/fad1caa0718ebf80beab08804cb9584938971c51))
* **app:** meeting logs keep daemon words private; synthetic keys behaviour-tested; badge follows display changes; snap resize through the animator ([#358](https://github.com/anatolykoptev/ox-say/issues/358)) ([00f8755](https://github.com/anatolykoptev/ox-say/commit/00f875592c786ce11c25452be8e384f9f45cc9a3))
* **app:** meeting name caps and daemon pre-filter, explicit capture gate end, AX wake pause, ru copy ([#370](https://github.com/anatolykoptev/ox-say/issues/370)) ([a9a3172](https://github.com/anatolykoptev/ox-say/commit/a9a31728c40de51178532a44b67fd03a5e78be31))
* **app:** meeting names stop at the daemon's caps on a character boundary ([#252](https://github.com/anatolykoptev/ox-say/issues/252)) ([#360](https://github.com/anatolykoptev/ox-say/issues/360)) ([3d56123](https://github.com/anatolykoptev/ox-say/commit/3d5612381d31f93c24bf69227181568a3eb59696))
* **app:** no dictation or speak starts during an update's daemon restart; old per-app auto picks migrated once ([#355](https://github.com/anatolykoptev/ox-say/issues/355)) ([6599320](https://github.com/anatolykoptev/ox-say/commit/6599320461d83d1ae30bfbb9ea95d7cad94a2c75))
* **app:** per-task Studio pills, pill re-check after unlock, export cleanup, safe meeting ids, PDF chapter numbers ([#322](https://github.com/anatolykoptev/ox-say/issues/322)) ([6dc1026](https://github.com/anatolykoptev/ox-say/commit/6dc10266de3b0ac2a0c209251e1cfb5c983c45b9))
* **app:** pill begin/end helper, no tccutil wait on main, notice time scaled to its length ([#304](https://github.com/anatolykoptev/ox-say/issues/304)) ([6e45faa](https://github.com/anatolykoptev/ox-say/commit/6e45faa7dea9c0ee155a90ca21020ca63f1464cc))
* **app:** remember a slow clipboard, recheck focus, updater timeout and stale-copy tail ([#317](https://github.com/anatolykoptev/ox-say/issues/317)) ([105c1d1](https://github.com/anatolykoptev/ox-say/commit/105c1d1315052150d0f53939155d28a766b18da5))
* **app:** share the slow-clipboard memory with speak-selection, recheck focus after a read, exit-28 wording ([#319](https://github.com/anatolykoptev/ox-say/issues/319)) ([#324](https://github.com/anatolykoptev/ox-say/issues/324)) ([2be27b8](https://github.com/anatolykoptev/ox-say/commit/2be27b8c5e70cfa49836c03948f675278de5cd47))
* **app:** Studio voiceover flow, status menu and notices in the user's language ([#333](https://github.com/anatolykoptev/ox-say/issues/333)) ([#335](https://github.com/anatolykoptev/ox-say/issues/335)) ([f2a0d8a](https://github.com/anatolykoptev/ox-say/commit/f2a0d8ac65934ccbe6272ce0ed050d69230074a4))
* **app:** update, install and Create a Voice in the user's language; client design cap by spoken duration ([#332](https://github.com/anatolykoptev/ox-say/issues/332)) ([552fa41](https://github.com/anatolykoptev/ox-say/commit/552fa41b2c310f3ab3063c492f64b8f7f944cc87))
* **config,daemon,engine:** expose all engine paths in /status, name STT GPU values, drop test-only lease waits, README rows ([#307](https://github.com/anatolykoptev/ox-say/issues/307)) ([c6b84fe](https://github.com/anatolykoptev/ox-say/commit/c6b84fee68ed43f95e032b013a66ba110c08ca21))
* **daemon,bench:** voxcpm2 engine errors never show a path, paren guard sees through format chars; bench pins from the build stamp ([#350](https://github.com/anatolykoptev/ox-say/issues/350)) ([9ae1174](https://github.com/anatolykoptev/ox-say/commit/9ae1174db6041def5087c34ed016ae009c63d8bf))
* **daemon,engine,align:** a wedged interactive speak ends at a ceiling; Linux start token has the boot id; ox-align checks the WAV first ([#353](https://github.com/anatolykoptev/ox-say/issues/353)) ([29ed6df](https://github.com/anatolykoptev/ox-say/commit/29ed6df9f42944692ab49c16393485a685cab392))
* **daemon:** Go daemon nits - digit budget, log label, style lead, level codec, send-stamp pin, bench pidDir, ticker orphan ([#369](https://github.com/anatolykoptev/ox-say/issues/369)) ([15657e0](https://github.com/anatolykoptev/ox-say/commit/15657e077b3a641c95d61f10f23dc06a45f03f57))
* **daemon:** NFC search, .part.lock cleanup, warned pruning, store and echo-gate nits ([#298](https://github.com/anatolykoptev/ox-say/issues/298)) ([df09869](https://github.com/anatolykoptev/ox-say/commit/df09869a93a3404bec274399f8fa9eb6ff2b51da))
* **daemon:** plain notes snippets, short-word surname cut, Metal env for notes, voices repair fsync ([#318](https://github.com/anatolykoptev/ox-say/issues/318)) ([bf452d3](https://github.com/anatolykoptev/ox-say/commit/bf452d3ac4d4f0634faa5a3c69e7e356c5d475a7))
* **daemon:** refuse cross-site reads on every route; race-safe rename; tombstone clock fallback ([#276](https://github.com/anatolykoptev/ox-say/issues/276)) ([21146e8](https://github.com/anatolykoptev/ox-say/commit/21146e8617f63a8bc8b2718b18fddbf478bf7866))
* **dictation:** fall back to the other hotkey when the planned one is taken ([#283](https://github.com/anatolykoptev/ox-say/issues/283)) ([c343a14](https://github.com/anatolykoptev/ox-say/commit/c343a14732b5807c40530ef6b2d5af61452290c2))
* **dictation:** Lower All Sound pauses music when the output refuses the volume write ([#274](https://github.com/anatolykoptev/ox-say/issues/274)) ([3c495d3](https://github.com/anatolykoptev/ox-say/commit/3c495d36750dd35c627dd99f70106cf7ad093521))
* **duck:** keep partial restores owed, recover non-default devices, delay busy beep ([#300](https://github.com/anatolykoptev/ox-say/issues/300)) ([a377561](https://github.com/anatolykoptev/ox-say/commit/a37756195bf2f0ebfbeb1ca1e4f27de6c6523bae))
* **engine,daemon,meeting:** Shutdown waits for start attempts (flake [#347](https://github.com/anatolykoptev/ox-say/issues/347)); stray paths after markup; no dead Try Again ([#349](https://github.com/anatolykoptev/ox-say/issues/349)) ([3f7da4c](https://github.com/anatolykoptev/ox-say/commit/3f7da4ccc2798475b3912ca2a7d49d8c3a2a936d))
* **engine:** a speak queued behind a wedged voice child no longer blocks its recycle; cancel during the kill ([#343](https://github.com/anatolykoptev/ox-say/issues/343)) ([e481a8e](https://github.com/anatolykoptev/ox-say/commit/e481a8e8c158808862b99f490a9d6f70afce636e))
* **engine:** cap audiocpp prompt_audio at the voice_ref 5 MiB; correct the loopback-guard note ([#137](https://github.com/anatolykoptev/ox-say/issues/137)) ([#364](https://github.com/anatolykoptev/ox-say/issues/364)) ([3966039](https://github.com/anatolykoptev/ox-say/commit/39660392dfc4a302f4c77b08c565dbdf6e945adf))
* **engine:** fetch the pinned ggml submodule from our fork ([#375](https://github.com/anatolykoptev/ox-say/issues/375)) ([86a3b15](https://github.com/anatolykoptev/ox-say/commit/86a3b1595a759ecb9f33b52dc0183e361b71cf3c))
* **engine:** follow-ups of [#366](https://github.com/anatolykoptev/ox-say/issues/366) [#376](https://github.com/anatolykoptev/ox-say/issues/376) [#378](https://github.com/anatolykoptev/ox-say/issues/378) [#381](https://github.com/anatolykoptev/ox-say/issues/381) ([#382](https://github.com/anatolykoptev/ox-say/issues/382)) ([f9b4e3d](https://github.com/anatolykoptev/ox-say/commit/f9b4e3dcc08e5bb1e34e57e569b25be65e681782))
* **engine:** gate ox-align's padded WAV layout and the file path in CI; cap voice_ref paths in audiocpp ([#363](https://github.com/anatolykoptev/ox-say/issues/363), [#366](https://github.com/anatolykoptev/ox-say/issues/366)) ([#368](https://github.com/anatolykoptev/ox-say/issues/368)) ([3699ef9](https://github.com/anatolykoptev/ox-say/commit/3699ef9779b8533d81e02970ae1355b7d891edf8))
* **engine:** make pidfile remove atomic against the next start's write ([#331](https://github.com/anatolykoptev/ox-say/issues/331)) ([b292478](https://github.com/anatolykoptev/ox-say/commit/b2924787b3210c055835032e626046fc172d8517))
* **engine:** recycle a wedged voice child after a render deadline; keep interactive speak at full QoS during a render ([#156](https://github.com/anatolykoptev/ox-say/issues/156).7, [#156](https://github.com/anatolykoptev/ox-say/issues/156).12b) ([#336](https://github.com/anatolykoptev/ox-say/issues/336)) ([5139c05](https://github.com/anatolykoptev/ox-say/commit/5139c057b668145c37506be596ed5927008a9694))
* **engine:** stt segmenter reaches back over the warm run before an onset ([#379](https://github.com/anatolykoptev/ox-say/issues/379)) ([#380](https://github.com/anatolykoptev/ox-say/issues/380)) ([3543931](https://github.com/anatolykoptev/ox-say/commit/3543931515590cb61f3381a7d33d30ae81a035b9))
* **install:** resume big downloads from the .part, entitlement key count, staging and MCP checks ([#297](https://github.com/anatolykoptev/ox-say/issues/297)) ([d28b6b1](https://github.com/anatolykoptev/ox-say/commit/d28b6b17687f70a7161478e9e1012a0b898f89f2))
* **meeting:** keep a held speaker merge on a refused pick; tolerate unknown status and stray warnings; longer timeout for texts ([#260](https://github.com/anatolykoptev/ox-say/issues/260) [#231](https://github.com/anatolykoptev/ox-say/issues/231)) ([#282](https://github.com/anatolykoptev/ox-say/issues/282)) ([90385be](https://github.com/anatolykoptev/ox-say/commit/90385be309520112c684afe08e60f3f7ad380328))
* **meeting:** one owner per person across scripts; no raw HTML in notes and transcripts ([#273](https://github.com/anatolykoptev/ox-say/issues/273)) ([52d7575](https://github.com/anatolykoptev/ox-say/commit/52d7575f473204c0440c92a4fded52984f3b30b7))
* **meeting:** retention decides under the store lock; a finished meeting survives missing audio; one readiness probe per list ([#344](https://github.com/anatolykoptev/ox-say/issues/344)) ([299045b](https://github.com/anatolykoptev/ox-say/commit/299045b5b5f0c4084e664c59661001c468bd1835))
* **meetings:** daemon and store followups ([#243](https://github.com/anatolykoptev/ox-say/issues/243) [#244](https://github.com/anatolykoptev/ox-say/issues/244) [#252](https://github.com/anatolykoptev/ox-say/issues/252) [#256](https://github.com/anatolykoptev/ox-say/issues/256) [#258](https://github.com/anatolykoptev/ox-say/issues/258) [#260](https://github.com/anatolykoptev/ox-say/issues/260)) ([#262](https://github.com/anatolykoptev/ox-say/issues/262)) ([8141df0](https://github.com/anatolykoptev/ox-say/commit/8141df022a8ce4c09f46eef788eef4e49ca58c5d))
* **meetings:** recorder retry token, tap overlap and start off main, Don't-record vs Ask, no ghost rows ([#294](https://github.com/anatolykoptev/ox-say/issues/294)) ([be84dbf](https://github.com/anatolykoptev/ox-say/commit/be84dbfc49254133405825a01a72b8288033e584))
* **meeting:** the echo gate keeps the user's own talk-over turns ([#275](https://github.com/anatolykoptev/ox-say/issues/275)) ([28407b4](https://github.com/anatolykoptev/ox-say/commit/28407b4bc9342faab12faa31944f7b15eeaba47c))
* **notes:** bound the model check; at most two model loads per notes run, with the cause recorded ([#278](https://github.com/anatolykoptev/ox-say/issues/278)) ([7389a08](https://github.com/anatolykoptev/ox-say/commit/7389a082fbe7b3071a33fce2e6439b496c059f00))
* **notes:** model text can never become a link or image; surname rename in place ([#296](https://github.com/anatolykoptev/ox-say/issues/296)) ([768d105](https://github.com/anatolykoptev/ox-say/commit/768d10568db7018c1be9843d119505413ddd8ff0))
* **produce,voices:** permanent voice-read errors, path scrub, English numerals, initials, cold-start slack ([#321](https://github.com/anatolykoptev/ox-say/issues/321)) ([0ef208a](https://github.com/anatolykoptev/ox-say/commit/0ef208a3a48560a82c57467e257e811e4f43a03d))
* **produce:** English scripts keep digits, --timeout, WER/vscript/take/loudness/assembly/producer leftovers ([#311](https://github.com/anatolykoptev/ox-say/issues/311)) ([a2a2fd7](https://github.com/anatolykoptev/ox-say/commit/a2a2fd73829f266dd1734e8941551e4c7731409e))
* **produce:** strict no-clobber publish, loudness and producer status fixes, literal markdown in search snippets ([#327](https://github.com/anatolykoptev/ox-say/issues/327)) ([39a1976](https://github.com/anatolykoptev/ox-say/commit/39a19769740bec051a799e6cce4a00b473bbdcf5))
* **release,engine:** newest release commit, Allow on 405, ox-diar loader seam, doc notes ([#315](https://github.com/anatolykoptev/ox-say/issues/315)) ([4958b37](https://github.com/anatolykoptev/ox-say/commit/4958b37cb16de5ec49311f0f72eb6714cb1fcab9))
* **release:** stapler retry, stronger arm64 guard, fail-closed engine checks, one tag check ([#290](https://github.com/anatolykoptev/ox-say/issues/290)) ([0bfa484](https://github.com/anatolykoptev/ox-say/commit/0bfa484e6034471e21232dce47bdd93b9ebbd76d))
* **speak:** bound runaway generation, split long text instead of cutting it, default seed ([#285](https://github.com/anatolykoptev/ox-say/issues/285)) ([567b226](https://github.com/anatolykoptev/ox-say/commit/567b226eaba71f30a771e12ae8b4f0605416b59e))
* **speak:** never replace an iPhone copy with the speak hotkey's cmd-C ([#220](https://github.com/anatolykoptev/ox-say/issues/220)), harden the AX read ([#222](https://github.com/anatolykoptev/ox-say/issues/222)), gate the remote marker ([#158](https://github.com/anatolykoptev/ox-say/issues/158)) ([#291](https://github.com/anatolykoptev/ox-say/issues/291)) ([26ea13d](https://github.com/anatolykoptev/ox-say/commit/26ea13d9c5f1c2a0274f2f16e31fe7f27dd60160))
* **stt:** decode every chunk with comfort-noise edge context — Parakeet no longer drops speech ([#281](https://github.com/anatolykoptev/ox-say/issues/281)) ([395a22e](https://github.com/anatolykoptev/ox-say/commit/395a22ebb48354d2d785a85845142dfc1a0a9e3f))
* **stt:** re-decode at finish only when it fits a time budget ([#378](https://github.com/anatolykoptev/ox-say/issues/378)) ([#385](https://github.com/anatolykoptev/ox-say/issues/385)) ([4afa319](https://github.com/anatolykoptev/ox-say/commit/4afa319a5fb1cfb5036ed7ea4e37ff12e877e69d))
* **stt:** silent re-decode off at budget 0, drop dead skip-line branch, pin the zero-sum guard ([#386](https://github.com/anatolykoptev/ox-say/issues/386)) ([#389](https://github.com/anatolykoptev/ox-say/issues/389)) ([7c6e49b](https://github.com/anatolykoptev/ox-say/commit/7c6e49b7c423bd060a63f6c111100b4bd387a469))
* summary lines can't restyle notes, surname line breaks, seed mark strip, retry fits the deadline, installer nits ([#309](https://github.com/anatolykoptev/ox-say/issues/309)) ([de86650](https://github.com/anatolykoptev/ox-say/commit/de8665010cfc9d40c2fe9c9080e087af43e6f2b6))
* **updater:** bounded downloads with a stall guard; read the installed app; keep the install pill ([#287](https://github.com/anatolykoptev/ox-say/issues/287)) ([b30ec94](https://github.com/anatolykoptev/ox-say/commit/b30ec9454d2c927c1f3f72f445ad923a52d90903))
* **voices,daemon:** atomic voxcpm2 config, duration-aware design cap, scrubRoot names, SameWord fingerprint ([#326](https://github.com/anatolykoptev/ox-say/issues/326)) ([b1b9611](https://github.com/anatolykoptev/ox-say/commit/b1b9611929e6b9946e147e3e68667d37bbcde8e8))
* **voices:** cache the repair verdict; crash-safe repair test; healthy-voice fixtures ([#277](https://github.com/anatolykoptev/ox-say/issues/277)) ([72279cd](https://github.com/anatolykoptev/ox-say/commit/72279cda3fb776a20c8fdcdf1019629233931e09))
* **voices:** strict PATCH, forgiving model names, 502 without addresses, atomic and private voice design ([#308](https://github.com/anatolykoptev/ox-say/issues/308)) ([b031b00](https://github.com/anatolykoptev/ox-say/commit/b031b004863b7ee5c24f223773dda1fa80afc502))


### Changed

* **engine:** one WAV reader for ox-stt and ox-align, decoded straight into the padded buffer ([#13](https://github.com/anatolykoptev/ox-say/issues/13)) ([#362](https://github.com/anatolykoptev/ox-say/issues/362)) ([b49960e](https://github.com/anatolykoptev/ox-say/commit/b49960e266dadc9ecbbced98bc5103b5ed0092d0))

## [0.1.28](https://github.com/anatolykoptev/ox-say/compare/v0.1.27...v0.1.28) (2026-10-23)


### Fixed

* **dictation:** a dictation survives a daemon restart; [#213](https://github.com/anatolykoptev/ox-say/issues/213) follow-ups ([#217](https://github.com/anatolykoptev/ox-say/issues/217)) ([d4c689b](https://github.com/anatolykoptev/ox-say/commit/d4c689b775bab3b5568dd63f28a7f2579261d0bc))
* **dictation:** duck restores expire and use a relative quiet check; sign-release checks entitlements key by key ([#215](https://github.com/anatolykoptev/ox-say/issues/215)) ([892d968](https://github.com/anatolykoptev/ox-say/commit/892d96808f71b1fb0b08a739ca58f172f4a53796))
* **dictation:** read the selection through Accessibility before ⌘C; the Speaking pill never covers a dictation ([#219](https://github.com/anatolykoptev/ox-say/issues/219)) ([9a75c33](https://github.com/anatolykoptev/ox-say/commit/9a75c33abf29bf0308de09a46942f9fd790a63d7))

## [0.1.27](https://github.com/anatolykoptev/ox-say/compare/v0.1.26...v0.1.27) (2026-10-23)


### Fixed

* **align:** catch every exception in main — exit 1, not 134; metallib review nits ([#208](https://github.com/anatolykoptev/ox-say/issues/208)) ([637c1ed](https://github.com/anatolykoptev/ox-say/commit/637c1ed31cc811a383a7e09ae8e139a857a8caf9))
* **dictation:** an update install waits for the dictation, and the notices that matter are kept ([#209](https://github.com/anatolykoptev/ox-say/issues/209)) ([935935e](https://github.com/anatolykoptev/ox-say/commit/935935e30e32df398f02f471c08f9d5670b8746f))
* **dictation:** type the text when the clipboard holds an iPhone copy — the copy survives ([#212](https://github.com/anatolykoptev/ox-say/issues/212)) ([cec1526](https://github.com/anatolykoptev/ox-say/commit/cec1526e40a98f4bee2fe05eeabdc5cf17fe5383))

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
