import AppKit
import Combine
import DictationCore
import SwiftUI

/// The one main window. "Open OxSay…" opens it or brings it forward — a second
/// click focuses the same NSWindow, never creates another. While it is open the
/// app is `.regular` with a menu bar; when it closes the app returns to
/// `.accessory` once nothing that counts is left on screen.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    /// The single window; kept across close/reopen so its autosaved frame holds.
    private(set) var window: NSWindow?
    /// The app delegate: the menu bar's typed `MainMenuAction`s (About) go here, and it hosts the window.
    private weak var appDelegate: AppDelegate?
    /// What the window shows, read from the daemon and the app's stores; made when the window is first opened.
    private(set) var source: MainWindowSource?
    private var observers: [NSObjectProtocol] = []
    /// Reinstalls the menu bar when the Advanced switch flips (⌘1... follow the sidebar).
    private var advancedObserver: AnyCancellable?
    /// Orders the delayed return to .accessory against a later open.
    private var revert = AccessoryRevert()

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    /// Opens the window or brings it forward — on the Space the user is on — and turns the app into a regular one for as
    /// long as it is up. `route` selects a section (and a meeting); without one the window shows where it was.
    func open(route: MainRoute? = nil) {
        guard let appDelegate else { return }
        // A close that is still waiting out its revert delay must not take the policy back from this open.
        revert.windowOpened()
        NSApp.setActivationPolicy(.regular)
        // The source is made first: the menu's ⌘1... follow its Advanced switch.
        let source = self.source ?? makeSource(appDelegate)
        self.source = source
        // The Edit menu is what makes ⌘V reach a text field — a posted
        // key-equivalent is matched against the main menu first, so dictation
        // into our own window needs it installed.
        MainMenuBar.install(appDelegateTarget: appDelegate, for: .regular, advanced: source.model.advanced)
        let window = self.window ?? makeWindow(source)
        self.window = window
        if let route { source.apply(route) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // On screen now, so the policy check of a pending revert sees a visible window; the Space it joins is the one
        // that is current (`MainWindowSpec.collectionBehavior`).
        window.orderFrontRegardless()
        // Activation runs on the next turn, after the window is on screen.
        DispatchQueue.main.async { [weak window] in
            Self.activateApp()
            window?.makeKeyAndOrderFront(nil)
        }
        // Every open reads the data again, here and nowhere else: the view has no `.task` of its own, which made
        // the first open run two passes.
        source.windowOpened()
    }

    /// The one place a source is made, so the Advanced observer exists exactly when the source does.
    private func makeSource(_ appDelegate: AppDelegate) -> MainWindowSource {
        let source = MainWindowSource(host: appDelegate.windowHost())
        observeAdvanced(source)
        return source
    }

    private func observeAdvanced(_ source: MainWindowSource) {
        advancedObserver = source.model.$advanced.dropFirst().sink { [weak self] on in
            guard let self, let appDelegate = self.appDelegate else { return }
            MainMenuBar.install(appDelegateTarget: appDelegate, for: .regular, advanced: on)
        }
    }

    /// Edit ▸ Find… (⌘F): answered by the source while the window exists; the command never opens it.
    func find() {
        guard window != nil else { return }
        source?.openFind()
    }

    /// A section key pressed while the window is already in front is only a section change: the policy, the
    /// menu and the order are already what `open` would set, and running it again would flash the window and
    /// re-read the data. Any other state takes the full open.
    func show(_ route: MainRoute) {
        if window?.isKeyWindow == true, let source {
            source.apply(route)
            return
        }
        open(route: route)
    }

    /// `activate()` is cooperative: macOS 26 declined it from a non-gesture open and left a window
    /// the keyboard cannot reach. This call activated, with no Space switch.
    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func syncVisibility() {
        guard let window else { return }
        source?.visibilityChanged(window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }

    /// NSWindowDelegate: the window is going away. The app returns to
    /// .accessory a beat later — the closing window needs a moment to leave
    /// NSApp.windows, and a quick close→reopen must not flicker the Dock icon.
    /// This close is the only trigger that re-evaluates the policy: a
    /// miniaturized main window reads as not visible, so re-evaluating on any
    /// other event would strand it under .accessory with no Dock tile to
    /// restore from — add no other trigger without handling that case.
    func windowWillClose(_ notification: Notification) {
        source?.windowClosed()
        let ticket = revert.windowClosed()
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowPolicy.accessoryRevertDelay) { [weak self] in
            guard let self, self.revert.shouldRevert(ticket) else { return }
            self.applyPolicy()
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
        MainMenuBar.install(appDelegateTarget: appDelegate, for: policy, advanced: source?.model.advanced ?? false)
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
        let hosting = NSHostingController(rootView: MainView(source: source))
        // The content never resizes the window: a notice that wraps must not move the frame the user chose.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = L10nKey.windowTitle.text
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Opening brings the window to the user's current Space, a full-screen one included.
        window.collectionBehavior = MainWindowSpec.collectionBehavior
        window.contentMinSize = NSSize(width: MainWindowSpec.minimumWidth,
                                       height: MainWindowSpec.minimumHeight)
        // One controller owns the one window for the app's whole run.
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Minimised, covered or the app hidden: the window stops asking the daemon and stops its clock.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncVisibility() }
            })
        }
        window.setFrameAutosaveName(MainWindowSpec.frameAutosaveName)
        if !window.setFrameUsingName(MainWindowSpec.frameAutosaveName) {
            window.center()
        }
        return window
    }
}
