import AppKit
import AVFoundation
import Carbon
import DictationCore
import os
import ServiceManagement

/// The menu-bar app: an icon that shows the dictation state, a menu with the
/// settings, an overlay while dictating, and the wiring between the hotkey, the
/// recorder, the ox-say daemon and the paste output.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Toggle mode (press to start, press again to stop)", action: #selector(toggleMode), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
    private var shortcutItems: [Shortcut: NSMenuItem] = [:]
    private var hotKey: HotKey?
    private var escapeKey: HotKey?
    private var controller: DictationController!
    private let recorder = MicRecorder()
    private let output = PasteOutput()
    private let overlay = Overlay()
    private let speakService = SpeakServiceProvider()
    private let player = AudioPlayer()
    private var speechClient: SpeechClient!
    private let voiceSubmenu = NSMenu()
    private let speakVoiceKey = "speakVoice"
    /// Voices fetched from the daemon; nil until the first answer arrives.
    private var knownVoices: [String]?
    private var voicesLoading = false
    /// Bumped per speak request, so a late answer cannot stop the playback of a
    /// newer one.
    private var speakGeneration = 0
    private let modeKey = "hotkeyMode"
    private let shortcutKey = "shortcut"
    /// The last problem worth telling the user; the menu shows it until the
    /// next dictation starts.
    private var lastNotice: String?
    private var client: TranscriptionClient!
    /// Counts the seconds of a transcription on the pill, and after a while says
    /// why it takes long (CPU while the voice engine is loaded, or the GPU's
    /// first run after an update), so a slow run does not look like a hang.
    private var workingTimer: Timer?
    private var workingStarted = Date()
    private var slowReason: String?
    /// Bumped per transcription, so a late /status answer for one cannot label the next.
    private var workingGeneration = 0
    /// Why the recording ended on its own (length cap, microphone change); said
    /// once the text has been delivered.
    private var endedReason: String?
    private var termSource: DispatchSourceSignal?
    /// The key that is registered right now; what the menu tells the user to press.
    private var active: Shortcut?
    private let fallbackNoticeKey = "fallbackNoticeShownFor"
    /// The key the last successful registration used, kept across launches.
    private let keyInUseKey = "dictationKeyInUse"
    /// The key last reported as held by another app, so an open menu does not
    /// repeat the notice and the beep while the conflict lasts.
    private var registerFailNoticeShownFor: Shortcut?

    /// What the system shortcuts right now mean for the offered keys: which
    /// one dictation should listen to and what each menu item shows.
    private func shortcutPlan() -> ShortcutMenu.Plan {
        let defaults = UserDefaults.standard
        return ShortcutMenu.plan(
            stored: defaults.string(forKey: shortcutKey).flatMap(Shortcut.init(rawValue:)).map(choice),
            active: active.map(choice),
            lastSession: defaults.string(forKey: keyInUseKey).flatMap(Shortcut.init(rawValue:)).map(choice),
            choices: Shortcut.allCases.map(choice),
            system: Shortcut.systemShortcuts())
    }

    private func choice(_ shortcut: Shortcut) -> ShortcutMenu.Choice {
        ShortcutMenu.Choice(title: shortcut.title, keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let baseURL = DaemonAddress.url(agentPlist: try? Data(contentsOf: DaemonAddress.agentPlist))
        let client = TranscriptionClient(baseURL: baseURL)
        self.client = client
        speechClient = SpeechClient(baseURL: baseURL)
        speakService.onSpeak = { [weak self] text in self?.speak(text) }
        NSApp.servicesProvider = speakService
        overlay.onPlaybackToggle = { [weak self] in self?.player.toggle() }
        overlay.onPlaybackStop = { [weak self] in
            self?.player.stop()
            self?.overlay.finishPlaying()
        }
        overlay.playbackPosition = { [weak self] in
            guard let self else { return (0, 0, false) }
            return (self.player.currentTime, self.player.duration, self.player.isPaused)
        }
        player.onFinish = { [weak self] in self?.overlay.finishPlaying() }
        let streamer = StreamingTranscriber(baseURL: baseURL)
        let mode = HotkeyMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .hold
        controller = DictationController(recorder: recorder, output: output, mode: mode, transcriber: streamer)
        streamer.onText = { [overlay] text in overlay.setLiveText(text) }
        controller.onState = { [weak self] state in self?.show(state) }
        controller.onError = { [weak self] message in self?.notice(message, kind: .outcome) }
        // One line per dictation, no text: read with
        // `log show --predicate 'subsystem == "io.github.anatolykoptev.ox-say.dictation"'`.
        // Notice level, so the unified log persists it.
        let timingLog = Logger(subsystem: "io.github.anatolykoptev.ox-say.dictation", category: "timing")
        controller.onTiming = { timing in timingLog.notice("\(timing.line, privacy: .public)") }
        controller.onBusy = { NSSound.beep() }
        output.onNotice = { [weak self] message in self?.notice(message, kind: .outcome) }
        recorder.onLevels = { [overlay] levels in overlay.setLevels(levels) }
        recorder.onEnded = { [weak self] reason in
            // Transcribe what was recorded; say why it ended once it is delivered.
            guard let self, self.controller.state == .recording else { return }
            self.endedReason = reason
            self.controller.finishRecording()
        }
        // The pasted text is a promise this process keeps; give the clipboard
        // back before quitting, also on a plain `kill`.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        registerShortcut(shortcutPlan())
        show(.idle)

        // Ask for both permissions up front, so the first dictation does not stall
        // on a prompt. The Accessibility prompt shows once; the microphone prompt
        // too, then both live in System Settings → Privacy & Security.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        output.settle()
    }

    /// Registers the plan's key. A forced move off a key macOS took is said
    /// once per taken key (remembered across launches); a first registration
    /// and a move back to a freed pick stay silent.
    private func registerShortcut(_ plan: ShortcutMenu.Plan) {
        hotKey = nil
        active = nil
        applyShortcutItems(plan.items)
        guard let index = plan.key else {
            notice("Every dictation key is a macOS shortcut on this Mac. Free ⌃Space or ⌥Space in System Settings → Keyboard → Keyboard Shortcuts.")
            return
        }
        let key = Shortcut.allCases[index]
        hotKey = HotKey(keyCode: key.keyCode, modifiers: key.modifiers)
        hotKey?.onDown = { [weak self] in self?.controller.keyDown() }
        hotKey?.onUp = { [weak self] in self?.controller.keyUp() }
        guard hotKey != nil else {
            // Once per key per launch: menuWillOpen re-registers while active
            // stays nil, and the conflict usually outlasts the menu open.
            if registerFailNoticeShownFor != key {
                registerFailNoticeShownFor = key
                notice("\(key.title) is taken by another app, so dictation has no hotkey. Pick another one in this menu.")
            }
            return
        }
        registerFailNoticeShownFor = nil
        active = key
        let defaults = UserDefaults.standard
        defaults.set(key.rawValue, forKey: keyInUseKey)
        if let from = plan.movedFrom {
            let taken = Shortcut.allCases[from]
            if defaults.string(forKey: fallbackNoticeKey) != taken.rawValue {
                defaults.set(taken.rawValue, forKey: fallbackNoticeKey)
                notice("\(taken.title) is a macOS shortcut on this Mac, so dictation uses \(key.title).")
            }
        } else {
            defaults.removeObject(forKey: fallbackNoticeKey)
        }
    }

    /// The menu items follow the live system shortcuts: a key macOS freed is
    /// clickable again, a key it took greys out — whether or not the
    /// registered key changes.
    private func applyShortcutItems(_ rows: [ShortcutMenu.Item]) {
        for (index, shortcut) in Shortcut.allCases.enumerated() {
            guard let item = shortcutItems[shortcut] else { continue }
            let row = rows[index]
            item.state = row.isOn ? .on : .off
            item.isEnabled = row.isEnabled
            item.title = row.title
        }
    }

    /// System Settings may have freed or taken a key since: the items always
    /// follow it, and the registered key moves only when the plan says so.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildVoiceMenu()
        refreshVoices()
        let plan = shortcutPlan()
        let open = ShortcutMenu.onOpen(plan, registered: active.flatMap { Shortcut.allCases.firstIndex(of: $0) },
                                       idle: controller.state == .idle)
        guard open.register else {
            applyShortcutItems(open.items)
            return
        }
        registerShortcut(plan)
        show(.idle)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let shortcuts = NSMenu()
        shortcuts.autoenablesItems = false // or AppKit re-enables the greyed-out keys
        for choice in Shortcut.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(pickShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            shortcuts.addItem(item)
            shortcutItems[choice] = item
        }
        let shortcutMenu = NSMenuItem(title: "Dictation key", action: nil, keyEquivalent: "")
        shortcutMenu.submenu = shortcuts
        menu.addItem(shortcutMenu)
        toggleItem.target = self
        toggleItem.state = controller.mode == .toggle ? .on : .off
        menu.addItem(toggleItem)
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let voiceItem = NSMenuItem(title: "Speak voice", action: nil, keyEquivalent: "")
        voiceItem.submenu = voiceSubmenu
        menu.addItem(voiceItem)
        let hint = NSMenuItem(title: "Speak: select text, then right-click → Services", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Microphone settings…", action: #selector(openMicrophoneSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Accessibility settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OxSay Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func show(_ state: DictationState) {
        let symbol: String
        switch state {
        case .idle:
            symbol = "mic"
            statusLine.title = lastNotice ?? active.map { key in
                controller.mode == .hold ? "Hold \(key.title) and speak" : "Press \(key.title) to start and stop"
            } ?? "No dictation key"
            overlay.finish()
            if let reason = endedReason {
                endedReason = nil
                notice(reason)
            }
        case .recording:
            symbol = "mic.fill"
            lastNotice = nil
            statusItem.button?.toolTip = nil
            statusLine.title = "Listening… (esc cancels)"
            overlay.showListening()
        case .transcribing:
            symbol = "ellipsis.circle"
            statusLine.title = "Transcribing… (esc cancels)"
            // The paste goes to the app the user was dictating into, or nowhere.
            output.target = NSWorkspace.shared.frontmostApplication?.processIdentifier
            overlay.showWorking()
            startWorkingTimer()
        }
        if state != .transcribing {
            workingTimer?.invalidate()
            workingTimer = nil
        }
        // Esc cancels, but only while there is something to cancel: a registered
        // hotkey takes the key away from every other app.
        if state == .idle {
            // Not from inside the Esc handler itself: Carbon is still dispatching it.
            DispatchQueue.main.async { [weak self] in
                if self?.controller.state == .idle { self?.escapeKey = nil }
            }
        } else if escapeKey == nil {
            escapeKey = HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0)
            escapeKey?.onDown = { [weak self] in self?.controller.cancel() }
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OxSay Dictation")
        statusItem.button?.contentTintColor = state == .recording ? .systemRed : nil
    }

    private func startWorkingTimer() {
        workingTimer?.invalidate()
        workingStarted = Date()
        slowReason = nil
        workingGeneration += 1
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickWorking() }
        // .common: keep counting while the status-bar menu is open
        RunLoop.main.add(timer, forMode: .common)
        workingTimer = timer
    }

    private func tickWorking() {
        guard controller.state == .transcribing else { return }
        let elapsed = Date().timeIntervalSince(workingStarted)
        let seconds = Int(elapsed)
        if elapsed >= SlowTranscription.explainAfter(recordingSeconds: controller.recordingSeconds) && slowReason == nil {
            slowReason = "" // asked once per transcription
            let client = self.client!
            let generation = workingGeneration
            Task { @MainActor [weak self] in
                let state = await client.sttServerState()
                guard let self, self.workingGeneration == generation, self.controller.state == .transcribing else { return }
                self.slowReason = SlowTranscription.reason(sttServerState: state)
            }
        }
        guard seconds >= 3 else { return }
        if let reason = slowReason, !reason.isEmpty {
            overlay.setWorkingText("Transcribing… \(seconds)s · \(reason)")
        } else {
            overlay.setWorkingText("Transcribing… \(seconds)s")
        }
    }

    /// Synthesizes the text through the daemon and plays it. The pill says
    /// "Speaking…" for the wait; playback then runs in the background. A newer
    /// request supersedes an in-flight one, so a slow answer cannot stop what
    /// already plays.
    private func speak(_ text: String) {
        speakGeneration += 1
        let generation = speakGeneration
        overlay.showWorking()
        overlay.setWorkingText("Speaking…")
        overlay.setHintHidden(true)
        let client = speechClient!
        let voice = UserDefaults.standard.string(forKey: speakVoiceKey)
        Task { @MainActor [weak self] in
            do {
                let wav = try await client.speak(text, voice: voice)
                guard let self, self.speakGeneration == generation else { return }
                try self.player.play(wav: wav)
                self.overlay.showPlaying()
            } catch {
                guard let self, self.speakGeneration == generation else { return }
                self.overlay.finish()
                self.notice(String(describing: error))
            }
        }
    }

    /// Rebuilds the Speak voice submenu: the engine default plus the voices the
    /// daemon knows.
    private func rebuildVoiceMenu() {
        voiceSubmenu.removeAllItems()
        let current = UserDefaults.standard.string(forKey: speakVoiceKey)
        let fallback = NSMenuItem(title: "Engine default", action: #selector(pickVoice(_:)), keyEquivalent: "")
        fallback.target = self
        fallback.state = current == nil ? .on : .off
        voiceSubmenu.addItem(fallback)
        for name in knownVoices ?? [] {
            let item = NSMenuItem(title: name, action: #selector(pickVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == current ? .on : .off
            voiceSubmenu.addItem(item)
        }
        if knownVoices == nil {
            let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            voiceSubmenu.addItem(loading)
        }
    }

    /// Refreshes the daemon's voice list on every menu open; a failed fetch
    /// keeps the last good list and retries on the next open.
    private func refreshVoices() {
        guard !voicesLoading else { return }
        voicesLoading = true
        let client = speechClient!
        Task { @MainActor [weak self] in
            let voices = try? await client.voices()
            guard let self else { return }
            self.voicesLoading = false
            self.knownVoices = voices ?? self.knownVoices
            self.rebuildVoiceMenu()
        }
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            UserDefaults.standard.set(name, forKey: speakVoiceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: speakVoiceKey)
        }
        rebuildVoiceMenu()
    }

    private func notice(_ message: String, kind: DictationNotice.Kind = .unrelated) {
        // A recording that ended on its own says why together with what happened
        // to its text, not instead of it — and spends that reason on nothing else.
        let merged = DictationNotice.merge(endedReason: endedReason, into: message, kind: kind)
        endedReason = merged.endedReason
        lastNotice = merged.message
        statusLine.title = merged.message
        statusItem.button?.toolTip = merged.message
        overlay.showMessage(merged.message)
        NSSound.beep()
    }

    @objc private func pickShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, Shortcut(rawValue: raw) != nil else { return }
        controller.cancel()
        UserDefaults.standard.set(raw, forKey: shortcutKey)
        registerShortcut(shortcutPlan())
        show(controller.state)
    }

    @objc private func toggleMode() {
        controller.mode = controller.mode == .hold ? .toggle : .hold
        UserDefaults.standard.set(controller.mode.rawValue, forKey: modeKey)
        toggleItem.state = controller.mode == .toggle ? .on : .off
        show(controller.state)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notice("Start at login: \(error.localizedDescription)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
