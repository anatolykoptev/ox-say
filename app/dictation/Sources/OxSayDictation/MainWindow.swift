import AppKit
import DictationCore
import SwiftUI

/// The one main window. "Open OxSay…" opens it or brings it forward — a second
/// click focuses the same NSWindow, never creates another. While it is open the
/// app is `.regular` with a menu bar; when it closes the app returns to
/// `.accessory` once nothing that counts is left on screen.
final class MainWindowController: NSObject, NSWindowDelegate {
    /// The single window; kept across close/reopen so its autosaved frame holds.
    private var window: NSWindow?
    /// The app delegate: the .appDelegate menu actions (About) go here.
    private weak var appDelegate: AppDelegate?
    /// What the window shows, read from the daemon and the app's stores; made when the window is first opened.
    private(set) var source: MainWindowSource?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    /// Opens the window or brings it forward, and turns the app into a regular
    /// one for as long as it is up.
    func open() {
        guard let appDelegate else { return }
        NSApp.setActivationPolicy(.regular)
        // The Edit menu is what makes ⌘V reach a text field — a posted
        // key-equivalent is matched against the main menu first, so dictation
        // into our own window needs it installed.
        MainMenuBar.install(appDelegateTarget: appDelegate, for: .regular)
        let source = self.source ?? MainActor.assumeIsolated { MainWindowSource(host: appDelegate.windowHost()) }
        self.source = source
        let window = self.window ?? makeWindow(source)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Every open reads the data again: a kept window does not run its view's task a second time.
        MainActor.assumeIsolated { source.windowOpened() }
    }

    /// NSWindowDelegate: the window is going away. The app returns to
    /// .accessory a beat later — the closing window needs a moment to leave
    /// NSApp.windows, and a quick close→reopen must not flicker the Dock icon.
    /// This close is the only trigger that re-evaluates the policy: a
    /// miniaturized main window reads as not visible, so re-evaluating on any
    /// other event would strand it under .accessory with no Dock tile to
    /// restore from — add no other trigger without handling that case.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { source?.windowClosed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowPolicy.accessoryRevertDelay) { [weak self] in
            self?.applyPolicy()
        }
    }

    /// Re-reads the windows on screen, sets the matching activation policy and
    /// installs the menu that goes with it — under .accessory the bar shrinks
    /// to the Edit menu, so ⌘Q/⌘H/⌘W stop being live in our own modals.
    private func applyPolicy() {
        guard let appDelegate else { return }
        let policy = WindowPolicy.policy(for: NSApp.windows.map(describe))
        switch policy {
        case .regular:
            NSApp.setActivationPolicy(.regular)
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        }
        MainMenuBar.install(appDelegateTarget: appDelegate, for: policy)
    }

    /// The kind the policy is asked about. Only the main window's answer can
    /// change the outcome; every other window is described by what AppKit
    /// knows of it — a non-activating panel is the overlay pill, any other
    /// panel (the review sheet, the about panel, a future utility) is .panel.
    private func describe(_ window: NSWindow) -> WindowDescription {
        let kind: WindowKind
        if window === self.window {
            kind = .main
        } else if window is NSPanel && window.styleMask.contains(.nonactivatingPanel) {
            kind = .overlay
        } else {
            kind = .panel
        }
        return WindowDescription(kind: kind, canBecomeMain: window.canBecomeMain,
                                 visible: window.isVisible)
    }

    private func makeWindow(_ source: MainWindowSource) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(source: source)))
        window.title = L10nKey.windowTitle.text
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: MainWindowSpec.minimumWidth,
                                       height: MainWindowSpec.minimumHeight)
        // One controller owns the one window for the app's whole run.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName(MainWindowSpec.frameAutosaveName)
        if !window.setFrameUsingName(MainWindowSpec.frameAutosaveName) {
            window.center()
        }
        return window
    }
}
