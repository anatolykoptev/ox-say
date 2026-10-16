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
    /// Repair for a stale Accessibility grant; sits at the top of the menu
    /// only while the permission does not work (recomputed each open).
    private let allowPastingItem = NSMenuItem(title: "Allow pasting… (Accessibility is off)",
                                              action: #selector(allowPasting), keyEquivalent: "")
    /// Repair for a version split the kickstart could not fix: the same
    /// conditional top slot, offered only while the daemon stays off the
    /// on-disk bundle's version.
    private let repairItem = NSMenuItem(title: "Repair ox-say…",
                                        action: #selector(repairOxSay), keyEquivalent: "")
    /// The always-present top row that opens the main window.
    private let openItem = NSMenuItem(title: L10nKey.menuOpenOxSay.text,
                                    action: #selector(openMainWindow), keyEquivalent: "")
    /// Whether the Allow-pasting row is due, as of the last menu open; a
    /// handshake pass ending on an open menu re-syncs against it.
    private var wantAllowPasting = false
    private let toggleItem = NSMenuItem(title: "Toggle Mode (press to start, press again to stop)", action: #selector(toggleMode), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var hotKey: HotKey?
    private var escapeKey: HotKey?
    private var controller: DictationController!
    private let recorder = MicRecorder()
    private let output = PasteOutput()
    private let overlay = Overlay()
    private let speakService = SpeakServiceProvider()
    private let player = AudioPlayer()
    private var speechClient: SpeechClient!
    private var studioClient: StudioClient!
    private var studio: StudioController!
    /// The one main window; created on first "Open OxSay…", kept across closes.
    private lazy var mainWindow = MainWindowController(appDelegate: self)
    /// Runs once when the playback that was started with a completion ends on its own.
    private var playbackDone: (() -> Void)?
    /// The daemon's last /status answer, fetched on every menu open; nil when it
    /// could not be reached.
    private var serviceStatus: DaemonStatus?
    /// Version-handshake episode state (DictationCore): the disk version being
    /// chased, the kickstarts spent on it, and the version Repair would
    /// reinstall. A /status answer matching the disk version ends the episode.
    private var handshake = VersionHandshake.Episode()
    /// True while a handshake pass runs, so a /status refresh arriving during
    /// a kickstart's backoff does not stack a second pass.
    private var handshakeRunning = false
    /// True when the last pass held an action back for work in flight: the
    /// moment that work ends, a fresh /status is read and the pass runs again.
    private var handshakeDeferred = false
    /// The overlay's owner count when the handshake put its "Finishing the
    /// update…" text up; nil when the handshake has no text showing. The pill
    /// is cleared only while that count still stands — another owner taking it
    /// moves the count on.
    private var handshakePillOwner: Int?
    private var wakeObserver: NSObjectProtocol?
    /// The small version line at the bottom of the menu.
    private let footerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updater = UpdateChecker()
    /// True from the menu click until the result alert is up, so a second click
    /// does not stack a second check.
    private var updateCheckRunning = false
    /// True from the moment Update is chosen until installUpdate ends, however
    /// it ends; Check for Updates is refused meanwhile (a second get.sh would
    /// race the first on the same install).
    private var updateInstalling = false
    private let voiceSubmenu = NSMenu()
    /// One submenu for both hotkeys; its rows are rebuilt from the latest plans.
    private let shortcutsSubmenu = NSMenu()
    private var dictationKeyRows: [ShortcutMenu.Item] = []
    private var speakKeyRows: [ShortcutMenu.Item] = []
    private let speakVoiceRUKey = "speakVoiceRU"
    private let speakVoiceENKey = "speakVoiceEN"
    /// The single choice from before the per-language menus; migrated into
    /// both on first launch of a build that has them.
    private let legacySpeakVoiceKey = "speakVoice"
    /// Voices fetched from the daemon; nil until the first answer arrives.
    private var knownVoices: [String]?
    private var voicesLoading = false
    /// Bumped per speak request, so a late answer cannot stop the playback of a
    /// newer one.
    private var speakGeneration = 0
    /// True from a speak request until its audio is in hand (or it failed);
    /// the newest request owns it. A daemon restart or a relaunch in between
    /// would lose the synthesis.
    private var speakInFlight = false
    /// The speak-selection hotkey and its menu state; mirrors the dictation
    /// key machinery with its own offered combinations.
    private var speakHotKey: HotKey?
    private let capture = SelectionCapture()
    private let speakShortcutKey = "speakShortcut"
    private let speakKeyInUseKey = "speakKeyInUse"
    private var speakActive: SpeakShortcut?
    private var speakRegisterFailFor: SpeakShortcut?
    /// The "how to speak" hint line; its title follows the registered key.
    private let speakHint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
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

    /// The same plan question for the speak-selection key: which offered
    /// combination should be registered and what the menu rows show.
    private func speakShortcutPlan() -> ShortcutMenu.Plan {
        let defaults = UserDefaults.standard
        return ShortcutMenu.plan(
            stored: defaults.string(forKey: speakShortcutKey).flatMap(SpeakShortcut.init(rawValue:)).map(speakChoice),
            active: speakActive.map(speakChoice),
            lastSession: defaults.string(forKey: speakKeyInUseKey).flatMap(SpeakShortcut.init(rawValue:)).map(speakChoice),
            choices: SpeakShortcut.allCases.map(speakChoice),
            system: Shortcut.systemShortcuts())
    }

    private func speakChoice(_ shortcut: SpeakShortcut) -> ShortcutMenu.Choice {
        ShortcutMenu.Choice(title: shortcut.title, keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let baseURL = DaemonAddress.url(agentPlist: try? Data(contentsOf: DaemonAddress.agentPlist))
        let client = TranscriptionClient(baseURL: baseURL)
        self.client = client
        speechClient = SpeechClient(baseURL: baseURL)
        studioClient = StudioClient(baseURL: baseURL)
        studio = StudioController(host: studioHost())
        speakService.onSpeak = { [weak self] text in self?.speak(text) }
        NSApp.servicesProvider = speakService
        overlay.onPlaybackToggle = { [weak self] in self?.player.toggle() }
        overlay.onPlaybackStop = { [weak self] in
            self?.playbackDone = nil
            self?.player.stop()
            self?.overlay.finishPlaying()
        }
        overlay.playbackPosition = { [weak self] in
            guard let self else { return (0, 0, false) }
            return (self.player.currentTime, self.player.duration, self.player.isPaused)
        }
        player.onFinish = { [weak self] in
            self?.overlay.finishPlaying()
            let done = self?.playbackDone
            self?.playbackDone = nil
            done?()
            self?.handshakeWorkEnded()
        }
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
        // A settled paste nobody read is what a paste that went nowhere looks
        // like — the dictation claimed `delivered` and reached no app.
        output.onPasteSettled = { read in
            let outcome = read ? "yes" : "no"
            timingLog.notice("paste settled read=\(outcome, privacy: .public)")
        }
        output.onRemoteClipboardKept = {
            timingLog.notice("clipboard held a Universal Clipboard copy: not read, dictated text left on it")
        }
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
        registerSpeakShortcut(speakShortcutPlan())
        show(.idle)
        refreshServiceStatus()
        // A wake is the other moment the app and the daemon can split, e.g.
        // the daemon restarted while the Mac slept. It reuses the menu-open
        // /status refresh, which also runs the handshake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshServiceStatus() }
        studio.render()

        // Ask for both permissions up front, so the first dictation does not stall
        // on a prompt. The Accessibility prompt shows once; the microphone prompt
        // too, then both live in System Settings → Privacy & Security.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // One voice pref from before per-language picks applies to both.
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: legacySpeakVoiceKey) {
            defaults.removeObject(forKey: legacySpeakVoiceKey)
            if defaults.string(forKey: speakVoiceRUKey) == nil { defaults.set(legacy, forKey: speakVoiceRUKey) }
            if defaults.string(forKey: speakVoiceENKey) == nil { defaults.set(legacy, forKey: speakVoiceENKey) }
        }
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

    /// Registers the speak-selection key from the plan. The keypress fires
    /// once per press — there is no hold state to protect, so the plan is
    /// applied at any time, unlike the dictation key.
    private func registerSpeakShortcut(_ plan: ShortcutMenu.Plan) {
        speakHotKey = nil
        speakActive = nil
        applySpeakShortcutItems(plan.items)
        guard let index = plan.key else {
            notice("Every speak key is a macOS shortcut on this Mac. Free one in System Settings → Keyboard → Keyboard Shortcuts.")
            return
        }
        let key = SpeakShortcut.allCases[index]
        speakHotKey = HotKey(keyCode: key.keyCode, modifiers: key.modifiers)
        speakHotKey?.onDown = { [weak self] in self?.speakSelection() }
        guard speakHotKey != nil else {
            if speakRegisterFailFor != key {
                speakRegisterFailFor = key
                notice("\(key.title) is taken by another app, so speaking has no hotkey. Pick another one in this menu.")
            }
            return
        }
        speakRegisterFailFor = nil
        speakActive = key
        let defaults = UserDefaults.standard
        defaults.set(key.rawValue, forKey: speakKeyInUseKey)
        if let from = plan.movedFrom {
            let taken = SpeakShortcut.allCases[from]
            notice("\(taken.title) is a macOS shortcut on this Mac, so speaking uses \(key.title).")
        }
    }

    private func applySpeakShortcutItems(_ rows: [ShortcutMenu.Item]) {
        speakKeyRows = rows
        rebuildShortcutsMenu()
    }

    /// The menu rows follow the live system shortcuts: a key macOS freed is
    /// clickable again, a key it took greys out — whether or not the
    /// registered key changes.
    private func applyShortcutItems(_ rows: [ShortcutMenu.Item]) {
        dictationKeyRows = rows
        rebuildShortcutsMenu()
    }

    private func rebuildShortcutsMenu() {
        let rows = MenuSections.shortcutRows(dictation: dictationKeyRows, speak: speakKeyRows)
        MenuRenderer.fill(shortcutsSubmenu, rows: rows, target: self) { action in
            switch action {
            case .pickDictationKey(let index): return (#selector(pickShortcut(_:)), Shortcut.allCases[index].rawValue)
            case .pickSpeakKey(let index): return (#selector(pickSpeakShortcut(_:)), SpeakShortcut.allCases[index].rawValue)
            default: return (#selector(pickVoice(_:)), [String: String]())
            }
        }
    }

    /// System Settings may have freed or taken a key since: the items always
    /// follow it, and the registered key moves only when the plan says so.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildVoiceMenus()
        refreshVoices()
        refreshServiceStatus()
        studio.render()
        let plan = shortcutPlan()
        let open = ShortcutMenu.onOpen(plan, registered: active.flatMap { Shortcut.allCases.firstIndex(of: $0) },
                                       idle: controller.state == .idle)
        if open.register {
            registerShortcut(plan)
            show(.idle)
        } else {
            applyShortcutItems(open.items)
        }
        let speakPlan = speakShortcutPlan()
        let speakOpen = ShortcutMenu.onOpen(speakPlan, registered: speakActive.flatMap { SpeakShortcut.allCases.firstIndex(of: $0) },
                                            idle: true)
        if speakOpen.register {
            registerSpeakShortcut(speakPlan)
        } else {
            applySpeakShortcutItems(speakOpen.items)
        }
        speakHint.title = speakActive.map { "Speak: \($0.title) on a selection, or right-click → Services" }
            ?? "Speak: select text, then right-click → Services"
        // A grant recorded for a differently-signed build (an ad-hoc build's
        // cdhash, an older release) never matches again and the Settings
        // toggle cannot fix it; the repair item is offered only while the
        // grant does not work.
        wantAllowPasting = AccessibilityRepair.shouldOffer(accessibilityTrusted: AXIsProcessTrusted())
        // Both conditional top rows go through one plan, decided by what the
        // menu holds: the Repair row exists only while the daemon refuses the
        // bundle's version. The mismatch itself is never a menu state.
        syncTopRows(in: menu)
    }

    /// Brings the conditional top rows (Repair, Allow pasting) in line with
    /// what is wanted now — on a menu open, and on an open menu when a pass
    /// retracts or offers the repair. Membership decides, never "first
    /// item": inserting an item the menu already holds raises an Objective-C
    /// exception the app cannot survive.
    private func syncTopRows(in menu: NSMenu) {
        let items: [(TopRow, NSMenuItem)] = [(.repair, repairItem), (.allowPasting, allowPastingItem),
                                             (.openOxSay, openItem)]
        let current = menu.items.compactMap { item in items.first { $0.1 === item }?.0 }
        let plan = TopRows.plan(current: current, wantRepair: handshake.repairTarget != nil,
                                wantAllowPasting: wantAllowPasting)
        for row in plan.remove {
            guard let item = items.first(where: { $0.0 == row })?.1, item.menu === menu else { continue }
            menu.removeItem(item)
        }
        for insertion in plan.insert {
            guard let item = items.first(where: { $0.0 == insertion.row })?.1, item.menu == nil else { continue }
            menu.insertItem(item, at: min(insertion.index, menu.items.count))
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        allowPastingItem.target = self
        repairItem.target = self
        openItem.target = self
        menu.addItem(statusLine)
        speakHint.isEnabled = false
        menu.addItem(speakHint)
        menu.addItem(.separator())
        menu.addItem(submenuItem("Voice", voiceSubmenu))
        shortcutsSubmenu.autoenablesItems = false // or AppKit re-enables the greyed-out keys
        menu.addItem(submenuItem("Keyboard Shortcuts", shortcutsSubmenu))
        menu.addItem(submenuItem("Studio", studio.submenu))
        menu.addItem(.separator())
        menu.addItem(submenuItem("Settings", buildSettingsMenu()))
        menu.addItem(.separator())
        menu.addItem(withTitle: "About OxSay", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit OxSay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(.separator())
        footerItem.isEnabled = false
        menu.addItem(footerItem)
        updateFooter()
        // The managed top rows (Repair, Allow pasting, Open OxSay…) land above
        // the status line; syncTopRows keeps them in plan order on every open.
        syncTopRows(in: menu)
        statusItem.menu = menu
    }

    /// The bundle's version in small secondary-colour text, never clickable.
    private func updateFooter() {
        let text = MenuFooter.text(appVersion: AboutPanel.appVersion)
        footerItem.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// Asks the daemon for /status on every menu open; a failure clears the last
    /// answer so the About panel does not name a stale service version.
    private func refreshServiceStatus() {
        let client = studioClient!
        Task { @MainActor [weak self] in
            let status = try? await client.status()
            guard let self else { return }
            self.serviceStatus = status
            self.studio.statusChanged(status)
            self.runVersionHandshake()
        }
    }

    /// The on-disk bundle's version, read from its Info.plist file — never
    /// Bundle.main, which caches the plist this process launched with, the
    /// exact stale answer the handshake exists to catch.
    private static func diskVersion() -> String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"]) as? String
    }

    /// The work in this process a relaunch would lose and a daemon restart
    /// would fail mid-way. The daemon's own half is /status `idle`.
    private func appWork() -> VersionHandshake.AppWork {
        VersionHandshake.AppWork(dictating: controller.state != .idle,
                                 speaking: speakInFlight || player.isActivelyPlaying,
                                 designing: studio.designing,
                                 followingVoiceover: studio.followingVoiceover)
    }

    /// Work in this process ended: a pass that held an action back runs
    /// again, on a fresh /status (the daemon's busy flag may have cleared too).
    private func handshakeWorkEnded() {
        guard handshakeDeferred, appWork().idle else { return }
        refreshServiceStatus()
    }

    /// One pass of the version handshake over the latest /status: app, on-disk
    /// bundle and daemon should be one version. DictationCore's table decides;
    /// this gathers its inputs and performs what it returns. Skipped while an
    /// install runs — the installer is already moving the versions, and a
    /// kickstart then would fight its own agent reload. A kickstart or a
    /// relaunch never fires with work in flight — on the daemon's side
    /// (/status `idle`) or the app's — it waits for the work to end, and the
    /// guards are re-read before every action.
    private func runVersionHandshake() {
        guard !updateInstalling, !handshakeRunning else { return }
        handshakeRunning = true
        let client = studioClient!
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.handshakeRunning = false
                if let menu = self.statusItem.menu { self.syncTopRows(in: menu) }
            }
            let disk = Self.diskVersion()
            while !self.updateInstalling {
                switch self.handshake.decide(app: AboutPanel.appVersion, disk: disk,
                                             status: self.serviceStatus, work: self.appWork()) {
                case .none, .offerRepair:
                    self.handshakeDeferred = false
                    self.finishHandshakePill()
                    return
                case .deferUntilIdle:
                    self.handshakeDeferred = true
                    self.finishHandshakePill()
                    return
                case .relaunchSelf:
                    self.handshakeDeferred = false
                    self.relaunch()
                    return
                case .kickstartDaemon:
                    self.handshakeDeferred = false
                    self.showHandshakePill()
                    _ = await VersionHandshake.runKickstart(argv: VersionHandshake.kickstartCommand(uid: getuid()))
                    try? await Task.sleep(nanoseconds: UInt64(VersionHandshake.kickstartBackoff * 1_000_000_000))
                    let status = try? await client.status()
                    self.serviceStatus = status
                    self.studio.statusChanged(status)
                }
            }
            // An install started between actions: it owns the versions now.
            self.finishHandshakePill()
        }
    }

    /// The bounded "Finishing the update…" pill while a kickstart runs. A
    /// recording owns the pill, so during dictation the kickstart is silent.
    private func showHandshakePill() {
        guard controller.state == .idle else { return }
        overlay.showWorking()
        overlay.setWorkingText("Finishing the update…")
        overlay.setHintHidden(true)
        handshakePillOwner = overlay.owner
    }

    /// Clears the handshake's pill, but only while its own text is still the
    /// one showing: a speak, a studio pill or an install that took the overlay
    /// since keeps it.
    private func finishHandshakePill() {
        defer { handshakePillOwner = nil }
        guard let owner = handshakePillOwner, owner == overlay.owner, controller.state == .idle else { return }
        overlay.finish()
    }

    /// The user-chosen repair: reinstall the on-disk bundle's version over the
    /// mismatched service. Never automatic — the row exists only while the
    /// daemon stays off the bundle's version, and asks before running the
    /// installer.
    @objc private func repairOxSay() {
        guard let target = handshake.repairTarget else { return }
        guard UpdateGate.decide(installing: updateInstalling) == .proceed else {
            runAlert(title: UpdateGate.busyAlertTitle,
                     text: "Wait for it to finish; ox-say restarts when it is done.", buttons: ["OK"])
            return
        }
        let sure = runAlert(title: "Repair ox-say?",
                            text: "The app and the ox-say service disagree on the version. This reinstalls v\(target), the version already on disk; dictation pauses while ox-say restarts.",
                            buttons: ["Repair", "Cancel"])
        guard sure == .alertFirstButtonReturn else { return }
        installUpdate(tag: UpdateInstaller.tag(forVersion: target), kind: .update)
    }

    /// `open -n` this app's own bundle path — the current copy on disk — and
    /// end this process. The installer's success path and the handshake's
    /// relaunchSelf are the same act.
    private func relaunch() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunch.arguments = ["-n", Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        AboutPanel.show(serviceVersion: serviceStatus?.version)
    }

    /// "Open OxSay…": the one main window, opened or brought forward.
    @objc private func openMainWindow() {
        mainWindow.open()
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The extra settings: dictation mode, login item and the two permission panes.
    private func buildSettingsMenu() -> NSMenu {
        let settings = NSMenu()
        toggleItem.target = self
        toggleItem.state = controller.mode == .toggle ? .on : .off
        settings.addItem(toggleItem)
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settings.addItem(loginItem)
        settings.addItem(.separator())
        settings.addItem(withTitle: "Microphone Access…", action: #selector(openMicrophoneSettings), keyEquivalent: "").target = self
        settings.addItem(withTitle: "Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        return settings
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
            handshakeWorkEnded()
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

    /// Sends the text to the daemon with the pick for its script's language.
    private func speak(_ text: String) {
        let defaults = UserDefaults.standard
        let voice = VoicePick.voice(for: text,
                                    russian: defaults.string(forKey: speakVoiceRUKey),
                                    english: defaults.string(forKey: speakVoiceENKey))
        speakRequest(text, voice: voice)
    }

    /// Synthesizes the text through the daemon and plays it. The pill says
    /// "Speaking…" for the wait; playback then runs in the background. A newer
    /// request supersedes an in-flight one, so a slow answer cannot stop what
    /// already plays.
    private func speakRequest(_ text: String, voice: String?, language: String? = nil) {
        playbackDone = nil // a speech request supersedes a voiceover that was playing
        speakGeneration += 1
        let generation = speakGeneration
        speakInFlight = true
        overlay.showWorking()
        overlay.setWorkingText("Speaking…")
        overlay.setHintHidden(true)
        let client = speechClient!
        Task { @MainActor [weak self] in
            do {
                let wav = try await client.speak(text, voice: voice, language: language)
                guard let self, self.speakGeneration == generation else { return }
                self.speakInFlight = false
                try self.player.play(wav: wav)
                self.overlay.showPlaying()
            } catch {
                guard let self, self.speakGeneration == generation else { return }
                self.speakInFlight = false
                self.overlay.finish()
                self.notice(String(describing: error))
                self.handshakeWorkEnded()
            }
        }
    }

    /// Rebuilds the Voice submenu: per language the daemon's configured
    /// default, the engine's random voice, then the cloned voices the daemon knows.
    private func rebuildVoiceMenus() {
        let defaults = UserDefaults.standard
        let rows = MenuSections.voiceRows(known: knownVoices, russian: defaults.string(forKey: speakVoiceRUKey),
                                          english: defaults.string(forKey: speakVoiceENKey))
        MenuRenderer.fill(voiceSubmenu, rows: rows, target: self) { action in
            guard case .pickVoice(let slot, let name) = action else { return (#selector(pickVoice(_:)), [String: String]()) }
            // Each item carries the pref key it writes, so one selector serves both languages.
            var pick = ["key": slot == .russian ? speakVoiceRUKey : speakVoiceENKey]
            if let name { pick["voice"] = name }
            return (#selector(pickVoice(_:)), pick)
        }
    }

    /// Speaks a sample phrase through the just-picked voice, so a menu choice
    /// is heard right away. "Default voice" sends no voice — the explicit
    /// language routes it to that language's configured default even when a
    /// daemon-wide OX_SAY_LANG overrides script detection. A pick while
    /// speech plays supersedes it.
    private func previewVoice(key: String) {
        let russian = key == speakVoiceRUKey
        let text = russian ? "Это пример выбранного голоса." : "This is a preview of the selected voice."
        speakRequest(text, voice: UserDefaults.standard.string(forKey: key), language: russian ? "russian" : "english")
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
            self.rebuildVoiceMenus()
        }
    }

    /// What the Studio features use of the app: alerts, the pill, the player and the installer.
    private func studioHost() -> StudioHost {
        StudioHost(
            client: studioClient, speech: speechClient,
            russianVoicePick: { [unowned self] in UserDefaults.standard.string(forKey: self.speakVoiceRUKey) },
            alert: { [unowned self] title, text, buttons in self.runAlert(title: title, text: text, buttons: buttons) },
            pill: { [unowned self] text in
                if let text {
                    self.overlay.showWorking()
                    self.overlay.setWorkingText(text)
                    self.overlay.setHintHidden(true)
                } else {
                    self.overlay.finish()
                }
            },
            notify: { [unowned self] message in self.notice(message) },
            play: { [unowned self] wav, showPill, onFinish in
                self.playbackDone = onFinish
                do {
                    try self.player.play(wav: wav)
                    if showPill { self.overlay.showPlaying() }
                } catch {
                    self.playbackDone = nil
                    self.notice(String(describing: error))
                }
            },
            stopPlayback: { [unowned self] in
                self.playbackDone = nil
                self.player.stop()
            },
            installStudioVoice: { [unowned self] in self.installStudioVoice() },
            installing: { [unowned self] in self.updateInstalling },
            workEnded: { [unowned self] in self.handshakeWorkEnded() })
    }

    /// Install Studio Voice: confirm, then the update install pinned to the
    /// installed version with the studio model switched on.
    private func installStudioVoice() {
        guard UpdateGate.decide(installing: updateInstalling) == .proceed else {
            runAlert(title: UpdateGate.busyAlertTitle, text: "Wait for it to finish; ox-say restarts when it is done.", buttons: ["OK"])
            return
        }
        let sure = runAlert(title: "Install the studio voice?",
                            text: "Downloads the studio voice model once, about 3 GB. Dictation pauses for a few seconds while ox-say restarts.",
                            buttons: ["Install", "Cancel"])
        guard sure == .alertFirstButtonReturn else { return }
        installUpdate(tag: UpdateInstaller.tag(forVersion: AboutPanel.appVersion), kind: .studioVoice)
    }

    /// The menu's update check: GitHub's latest release against the bundle's
    /// build version. Every outcome ends in an alert that waits for the user —
    /// a pill message times out and is easy to miss.
    @objc private func checkForUpdates() {
        guard UpdateGate.decide(installing: updateInstalling) == .proceed else {
            runAlert(title: UpdateGate.busyAlertTitle, text: "Wait for it to finish; ox-say restarts when it is done.", buttons: ["OK"])
            return
        }
        guard !updateCheckRunning else { return }
        updateCheckRunning = true
        let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        overlay.showWorking()
        overlay.setWorkingText("Checking for updates…")
        overlay.setHintHidden(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let fetch: Result<(tag: String, url: URL?, body: String), UpdateError>
            do {
                fetch = .success(try await self.updater.latestRelease())
            } catch let error as UpdateError {
                fetch = .failure(error)
            } catch {
                fetch = .failure(.unreachable(error.localizedDescription))
            }
            self.overlay.finish()
            self.updateCheckRunning = false
            self.present(UpdatePrompt.make(local: local, fetch: fetch))
        }
    }

    /// Renders the prompt; the pure decision is UpdatePrompt.make.
    private func present(_ prompt: UpdatePrompt) {
        switch prompt {
        case .upToDate(let version):
            runAlert(title: "You're up to date", text: "ox-say v\(version) is the newest version.", buttons: ["OK"])
        case .available(let remote, let local, let notes, let url):
            confirmInstall(remote: remote, local: local, notes: notes, url: url)
        case .failed(let reason):
            if runAlert(title: "Couldn't check for updates", text: reason, buttons: ["Try Again", "OK"]) == .alertFirstButtonReturn {
                checkForUpdates()
            }
        }
    }

    /// Shows a modal alert over every app and returns the pressed button.
    @discardableResult
    func runAlert(title: String, text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        for button in buttons { alert.addButton(withTitle: button) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// Update / Later / Release Notes…; the notes button opens the release page
    /// and asks again, so reading them does not forfeit the decision.
    private func confirmInstall(remote: String, local: String, notes: String, url: URL?) {
        let text = notes.isEmpty ? "You have v\(local)." : "You have v\(local).\n\n\(notes)"
        let buttons = url == nil ? ["Update", "Later"] : ["Update", "Later", "Release Notes…"]
        switch runAlert(title: "ox-say \(remote) is available", text: text, buttons: buttons) {
        case .alertFirstButtonReturn:
            installUpdate(tag: remote, kind: .update)
        case .alertThirdButtonReturn:
            if let url { NSWorkspace.shared.open(url) }
            confirmInstall(remote: remote, local: local, notes: notes, url: url)
        default:
            break
        }
    }

    /// Where the installer's output of the last attempt lands.
    private static var updateLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ox-say/update.log")
    }

    /// Opens (truncating) the update log; nil when the directory or file cannot
    /// be created, in which case the installer's output is discarded.
    private static func openUpdateLog() -> FileHandle? {
        let url = updateLogURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return try? FileHandle(forWritingTo: url)
    }

    /// Installs the release (DictationCore's UpdateInstaller.run: download get.sh,
    /// run it, check the bundle's version). Output lands in the update log. The
    /// app relaunches only when the installed bundle really reports the target
    /// version; every other outcome is the failed alert. A successful install
    /// usually ends this process first: install-app.sh quits the running app and
    /// opens the new one, so nothing here may be needed after the install.
    private func installUpdate(tag: String, kind: UpdateInstaller.Kind) {
        updateInstalling = true
        studio.render()
        overlay.showWorking()
        overlay.setWorkingText(kind == .studioVoice ? "Installing the studio voice…" : "Installing \(tag)…")
        overlay.setHintHidden(true)
        Task { @MainActor in
            let log = Self.openUpdateLog()
            let statusClient = studioClient!
            let failure = await UpdateInstaller.run(kind: kind, tag: tag, log: log,
                                                    installedVersion: Self.diskVersion,
                                                    daemonVersion: { (try? await statusClient.status(timeout: UpdateInstaller.daemonCheckTimeout))?.version })
            try? log?.close()
            updateInstalling = false
            studio.render()
            if let failure {
                overlay.finish()
                runAlert(title: kind == .studioVoice ? "Installing the studio voice failed" : "Update to \(tag) failed",
                         text: "\(failure.message) Its output is in\n\(Self.updateLogURL.path)",
                         buttons: ["OK"])
                return
            }
            relaunch()
        }
    }

    /// The speak-selection hotkey press: read whatever is selected in the
    /// frontmost app and speak it, or say on the pill why nothing came.
    private func speakSelection() {
        let (text, problem) = capture.capture()
        if let text {
            speak(text)
        } else {
            overlay.showMessage(problem ?? "Nothing selected to speak.")
        }
    }

    @objc private func pickSpeakShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, SpeakShortcut(rawValue: raw) != nil else { return }
        UserDefaults.standard.set(raw, forKey: speakShortcutKey)
        registerSpeakShortcut(speakShortcutPlan())
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? [String: String],
              let key = pick["key"], key == speakVoiceRUKey || key == speakVoiceENKey else { return }
        if let name = pick["voice"] {
            UserDefaults.standard.set(name, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        rebuildVoiceMenus()
        previewVoice(key: key)
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

    /// "Allow pasting…": reset this app's own Accessibility entry so the trust
    /// prompt can store a grant matching the running build, then re-ask and
    /// open the pane. The reset is scoped to this app's bundle id and the one
    /// service, and offered only while the entry does not work — nothing
    /// else's TCC state is touched.
    @objc private func allowPasting() {
        let failure = "Could not refresh the Accessibility permission: remove OxSayDictation with − in System Settings → Privacy & Security → Accessibility, then add it again."
        guard let arguments = AccessibilityRepair.resetArguments(bundleID: Bundle.main.bundleIdentifier) else {
            return notice(failure)
        }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = arguments
        do {
            try reset.run()
        } catch {
            return notice(failure)
        }
        reset.waitUntilExit()
        guard reset.terminationStatus == 0 else {
            return notice(failure)
        }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        openAccessibilitySettings()
    }
}
