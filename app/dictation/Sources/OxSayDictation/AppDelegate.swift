import AppKit
import AVFoundation
import DictationCore
import ServiceManagement

/// The menu-bar app: an icon that shows the dictation state, a menu with the
/// settings, and the wiring between the hotkey, the recorder, the ox-say daemon
/// and the paste output.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Toggle mode (press to start, press again to stop)", action: #selector(toggleMode), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
    private var hotKey: HotKey?
    private var controller: DictationController!
    private let recorder = MicRecorder()
    private let output = PasteOutput()
    private let modeKey = "hotkeyMode"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let base = ProcessInfo.processInfo.environment["OX_SAY_URL"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:8094")!
        let client = TranscriptionClient(baseURL: base)
        let mode = HotkeyMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .hold
        controller = DictationController(recorder: recorder, output: output, mode: mode) { samples in
            try await client.transcribe(samples)
        }
        controller.onState = { [weak self] state in self?.show(state) }
        controller.onError = { [weak self] message in self?.notice(message) }
        output.onNotice = { [weak self] message in self?.notice(message) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        show(.idle)

        hotKey = HotKey()
        hotKey?.onDown = { [weak self] in self?.controller.keyDown() }
        hotKey?.onUp = { [weak self] in self?.controller.keyUp() }
        if hotKey == nil {
            notice("⌥Space is taken by another app, so dictation has no hotkey.")
        }

        // Ask for both permissions up front, so the first dictation does not stall
        // on a prompt. The Accessibility prompt shows once; the microphone prompt
        // too, then both live in System Settings → Privacy & Security.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
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
            statusLine.title = controller.mode == .hold ? "Hold ⌥Space and speak" : "Press ⌥Space to start and stop"
        case .recording:
            symbol = "mic.fill"
            statusLine.title = "Listening…"
        case .transcribing:
            symbol = "ellipsis.circle"
            statusLine.title = "Transcribing…"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OxSay Dictation")
        statusItem.button?.contentTintColor = state == .recording ? .systemRed : nil
    }

    private func notice(_ message: String) {
        statusLine.title = message
        statusItem.button?.toolTip = message
        NSSound.beep()
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
