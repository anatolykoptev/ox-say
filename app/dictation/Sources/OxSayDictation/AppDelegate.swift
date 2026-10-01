import AppKit
import AVFoundation
import Carbon
import DictationCore
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
    private let modeKey = "hotkeyMode"
    private let shortcutKey = "shortcut"
    /// The last problem worth telling the user; the menu shows it until the
    /// next dictation starts.
    private var lastNotice: String?
    private var client: TranscriptionClient!
    private var streamer: StreamingTranscriber!
    /// Recorder chunks ride a fresh AsyncStream per dictation, so they stay in
    /// order: the audio thread yields, one consumer task feeds each chunk to
    /// the transcriber tagged with the generation that dictation began under.
    private var feedRoute: FeedRoute?
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

    /// The chosen key, or the first one macOS does not already use.
    private var shortcut: Shortcut {
        if let chosen = Shortcut(rawValue: UserDefaults.standard.string(forKey: shortcutKey) ?? ""), chosen.isFree {
            return chosen
        }
        return Shortcut.allCases.first { $0.isFree } ?? .controlSpace
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let baseURL = DaemonAddress.url(agentPlist: try? Data(contentsOf: DaemonAddress.agentPlist))
        let client = TranscriptionClient(baseURL: baseURL)
        self.client = client
        let streamer = StreamingTranscriber(baseURL: baseURL)
        self.streamer = streamer
        let mode = HotkeyMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .hold
        controller = DictationController(recorder: recorder, output: output, mode: mode, transcriber: streamer)
        streamer.onText = { [overlay] text in overlay.setLiveText(text) }
        controller.onState = { [weak self] state in
            self?.routeFeed(state)
            self?.show(state)
        }
        controller.onError = { [weak self] message in self?.notice(message) }
        controller.onBusy = { NSSound.beep() }
        output.onNotice = { [weak self] message in self?.notice(message) }
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
        registerShortcut(announce: true)
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

    /// Rebuilds the chunk plumbing on dictation boundaries (onState fires only
    /// on transitions): a recording gets its own stream and consumer, tagged
    /// with the generation `begin` just minted; on stop or cancel the stream
    /// is finished and the consumer cancelled, so nothing of this dictation
    /// can be fed — or sent — once the next one starts.
    private func routeFeed(_ state: DictationState) {
        recorder.onSamples = nil
        feedRoute?.close()
        feedRoute = nil
        guard state == .recording, let streamer else { return }
        let route = FeedRoute(transcriber: streamer)
        feedRoute = route
        recorder.onSamples = route.sink
    }

    /// Registers the chosen key, or the first free one. `announce` says so when
    /// the choice had to fall back (once per choice, not at every launch).
    private func registerShortcut(announce: Bool) {
        hotKey = nil
        active = nil
        let key = shortcut
        for (choice, item) in shortcutItems {
            item.state = choice == key ? .on : .off
            item.isEnabled = choice.isFree
            item.title = choice.isFree ? choice.title : "\(choice.title) (a macOS shortcut)"
        }
        guard key.isFree else {
            if announce {
                notice("Every dictation key is a macOS shortcut on this Mac. Free ⌃Space or ⌥Space in System Settings → Keyboard → Keyboard Shortcuts.")
            }
            return
        }
        hotKey = HotKey(keyCode: key.keyCode, modifiers: key.modifiers)
        hotKey?.onDown = { [weak self] in self?.controller.keyDown() }
        hotKey?.onUp = { [weak self] in self?.controller.keyUp() }
        guard hotKey != nil else {
            if announce { notice("\(key.title) is taken by another app, so dictation has no hotkey. Pick another one in this menu.") }
            return
        }
        active = key
        let defaults = UserDefaults.standard
        if let chosen = Shortcut(rawValue: defaults.string(forKey: shortcutKey) ?? ""), chosen != key {
            if announce && defaults.string(forKey: fallbackNoticeKey) != chosen.rawValue {
                defaults.set(chosen.rawValue, forKey: fallbackNoticeKey)
                notice("\(chosen.title) is a macOS shortcut on this Mac, so dictation uses \(key.title).")
            }
        } else {
            defaults.removeObject(forKey: fallbackNoticeKey)
        }
    }

    /// System Settings may have freed or taken a key since: follow it.
    func menuWillOpen(_ menu: NSMenu) {
        if controller.state == .idle && active != shortcut {
            registerShortcut(announce: false)
            show(.idle)
        }
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

    private func notice(_ message: String) {
        // A recording that ended on its own says why together with what happened
        // to its text, not instead of it.
        let message = endedReason.map { "\($0) \(message)" } ?? message
        endedReason = nil
        lastNotice = message
        statusLine.title = message
        statusItem.button?.toolTip = message
        overlay.showMessage(message)
        NSSound.beep()
    }

    @objc private func pickShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, Shortcut(rawValue: raw) != nil else { return }
        controller.cancel()
        UserDefaults.standard.set(raw, forKey: shortcutKey)
        registerShortcut(announce: true)
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
