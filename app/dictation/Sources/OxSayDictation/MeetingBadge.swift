import AppKit
import DictationCore
import os

private let badgeLog = Logger(subsystem: "io.github.anatolykoptev.ox-say.dictation", category: "meeting")

/// The always-visible recording control: a small panel at the top of the screen
/// with a red dot, the clock, a level for each side and a Stop button; or, when
/// a call is detected and its policy is to ask, a question that names the app
/// with Record / Not now / Don't ask for <App>; or, before the first Apple Event
/// to a browser, the Automation-consent question with Allow… / Not now.
/// It is its own window, not the dictation pill, so a dictation never takes it
/// down and a recording never waits for one.
final class MeetingBadge {
    enum Mode: Equatable {
        case recording(auto: Bool)
        case prompt(source: String)
        /// Record was pressed on the prompt and the call is being re-checked: the prompt, its buttons off.
        case recordChecking(source: String)
        /// The check could not confirm the call: "may have ended — record anyway?" in the badge, no modal.
        case recordConfirm(source: String)
        /// macOS's Automation answer for this browser is undetermined: ask in context before the first Apple Event.
        case browserConsent(browser: String)
        /// A start that did not become a recording, with the reason in words. Stays until it is dismissed: an error
        /// that fades is an error nobody read (#518).
        case failed(text: String)
    }

    var onStop: (() -> Void)?
    var onDontRecord: (() -> Void)?
    var onRecord: (() -> Void)?
    var onNotNow: (() -> Void)?
    /// The record question's Record: the offered start. Its Cancel goes back to the prompt.
    var onConfirmRecord: (() -> Void)?
    var onConfirmCancel: (() -> Void)?
    /// "Don't ask for <App>": the prompt's third, quieter action.
    var onDontAsk: (() -> Void)?
    /// The Automation badge's "Allow…": the next tab read raises macOS's prompt in context.
    var onBrowserAllow: (() -> Void)?
    /// The Automation badge's "Not now": no Apple Event until the browser lets the microphone go.
    var onBrowserNotNow: (() -> Void)?
    var onCopyConsent: (() -> Void)?
    /// The plate is up and the window server says it is not on screen, and every self-heal failed (#517): the owner
    /// tells the user another way.
    var onNotVisible: (() -> Void)?
    /// Where the plate's spot per display is remembered.
    var defaults: UserDefaults = .standard

    private let panel: NSPanel
    private let stack = NSStackView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let meBar = NSProgressIndicator()
    private let themBar = NSProgressIndicator()
    /// Keeps the clock's slot as wide as the widest REC text, so the panel is sized
    /// for the text it will hold and the ticking clock never resizes it.
    private let labelWidth: NSLayoutConstraint
    private var consentButton: NSButton?
    private(set) var mode: Mode?
    /// The display the panel was last placed on, so a display change can tell whether it is still there.
    private var placedOn: UInt32?
    /// The panel's left edge from that display's left: kept across a change of the arrangement, whose global coordinates shift.
    private var placedOffset: Double?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// The gap under the top of that display's usable area: the vertical half of the panel's place.
    private var placedInset: Double?
    /// True while the app itself moves the panel, so a drag by the user is told from a placement.
    private var isPlacing = false
    private var watch = PlateWatch()
    private var lastVerified = Date.distantPast
    /// Seconds between two asks of the window server about a plate that is up.
    private static let verifyEvery: TimeInterval = 2
    /// Caps the label of an error, which is a sentence, so the plate stays on its screen.
    private let maxLabelWidth: NSLayoutConstraint
    /// The user folded the recording plate to its dot and clock; it starts expanded for every recording.
    private var userCollapsed = false
    private var recordingAuto = false
    private var lastElapsed: TimeInterval = 0

    /// The widest clock the label shows (digits are monospaced): 9:59:59.
    private static let widestElapsed: TimeInterval = 10 * 3600 - 1

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        PlateWindowSpec.apply(to: panel)
        // Dragged by any part that is not a button; where it is left is remembered per display.
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        panel.contentView = background

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        for bar in [meBar, themBar] {
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.controlSize = .mini
            bar.style = .bar
            bar.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        labelWidth = label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        maxLabelWidth = label.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        dot.setAccessibilityElement(true)
        dot.setAccessibilityRole(.image)
        dot.setAccessibilityLabel(L10nKey.badgeA11yDot.text)
        // A click on the dot of a collapsed plate opens it again.
        let dotClick = ActionTarget { [weak self] in
            guard let self, self.userCollapsed else { return }
            self.setCollapsed(false)
        }
        let recognizer = NSClickGestureRecognizer(target: dotClick, action: #selector(ActionTarget.fire))
        dot.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(dot, &Self.handlerKey, dotClick, .OBJC_ASSOCIATION_RETAIN)
        meBar.setAccessibilityLabel(L10nKey.badgeA11yMe.text)
        themBar.setAccessibilityLabel(L10nKey.badgeA11yThem.text)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                                              queue: .main) { [weak self] _ in self?.panelMoved() }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    var isVisible: Bool { panel.isVisible }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        let handler = ActionTarget(action)
        b.target = handler
        b.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(b, &Self.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
        return b
    }

    /// The prompt's least loud action, drawn smaller than the real buttons.
    private func quietButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = button(title, action)
        b.bezelStyle = .inline
        return b
    }

    /// A small symbol-only button (the fold and unfold of the recording plate), named for VoiceOver and the tooltip.
    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> NSButton {
        let b = button("", action)
        b.bezelStyle = .inline
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        b.imagePosition = .imageOnly
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }

    private static var handlerKey = 0

    private final class ActionTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    private func layout(_ views: [NSView], keepingPlace: Bool = false, capLabel: Bool = false) {
        maxLabelWidth.isActive = capLabel
        label.toolTip = capLabel ? label.stringValue : nil
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        views.forEach { stack.addArrangedSubview($0) }
        resize(keepingPlace: keepingPlace)
        panel.orderFrontRegardless()
    }

    /// Sizes the panel to what the stack holds now and centres it at the top of the
    /// screen. Called again whenever the content's width changes (the consent button
    /// hides, the clock outgrows its slot): a hidden arranged view drops out of the stack.
    /// `keepingPlace`: the badge is already on screen and only its width changed — it keeps its left edge instead of
    /// re-centring, so the buttons stay under the pointer (#251). A new content is centred.
    private func resize(keepingPlace: Bool) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let offset = keepingPlace && panel.isVisible ? placedOffset : nil
        let inset = keepingPlace && panel.isVisible ? placedInset : nil
        // A collapsed plate is its dot and clock; every other content keeps the width the buttons need.
        let minimum: CGFloat = PlateCollapse.presentation(isRecording: isRecording, userCollapsed: userCollapsed) == .collapsed ? 0 : 220
        panel.setContentSize(NSSize(width: max(size.width, minimum), height: 36))
        place(anchoredOffset: offset, anchoredInset: inset, onScreen: keepingPlace ? placedOn : nil)
    }

    private var isRecording: Bool {
        if case .recording? = mode { return true }
        return false
    }

    /// Puts the panel on a screen that exists now: `BadgePlacement.place` decides which one and where (DictationCore,
    /// table-tested); this reads the screens and moves the window.
    private func place(anchoredOffset: Double?, anchoredInset: Double? = nil, onScreen: UInt32?) {
        let screens = Self.placementScreens()
        // No screens (the lid closed, the display asleep): the badge stays where it is; the next change places it.
        guard let spot = BadgePlacement.place(screens: screens, placedOn: onScreen, main: NSScreen.main.flatMap(Self.displayID),
                                              anchoredOffset: anchoredOffset, anchoredInset: anchoredInset,
                                              saved: BadgePositions.load(defaults), width: Double(panel.frame.width),
                                              height: Double(panel.frame.height)) else { return }
        placedOn = spot.screenID
        placedOffset = spot.offset
        placedInset = spot.topInset
        isPlacing = true
        panel.setFrameOrigin(NSPoint(x: spot.x, y: spot.y))
        isPlacing = false
    }

    private static func placementScreens() -> [BadgePlacement.Screen] {
        NSScreen.screens.compactMap { screen -> BadgePlacement.Screen? in
            guard let id = displayID(screen) else { return nil }
            let frame = screen.visibleFrame
            return BadgePlacement.Screen(id: id, minX: Double(frame.minX), maxX: Double(frame.maxX), maxY: Double(frame.maxY),
                                         minY: Double(frame.minY))
        }
    }

    /// The user dragged the plate: its new place, on the display it now covers most, is what the next appearance and the
    /// next change of width keep.
    private func panelMoved() {
        guard !isPlacing, panel.isVisible else { return }
        let frame = panel.frame
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(centre, $0.frame, false) }),
              let id = Self.displayID(screen) else { return }
        let visible = screen.visibleFrame
        let dx = Double(frame.minX - visible.minX)
        let inset = Double(visible.maxY - frame.height - frame.minY)
        placedOn = id
        placedOffset = dx
        placedInset = inset
        BadgePositions.save(display: id, dx: dx, topInset: inset, defaults)
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A display was plugged, unplugged or changed its size: a badge that is up (prompt, consent question or recording)
    /// is placed again on a screen that still exists (#342.4). Nothing to do for a badge that is not on screen: its next
    /// content is placed when it appears.
    private func screensChanged() {
        guard panel.isVisible, mode != nil else { return }
        place(anchoredOffset: placedOffset, anchoredInset: placedInset, onScreen: placedOn)
    }

    func showRecording(auto: Bool, elapsed: TimeInterval) {
        guard mode != .recording(auto: auto) else { return }
        mode = .recording(auto: auto)
        userCollapsed = false
        recordingAuto = auto
        panel.setAccessibilityLabel(L10nKey.badgeA11yPanel.text)
        layoutRecording(elapsed: elapsed)
    }

    /// The recording plate, whole or folded to its dot and clock. Both are the same panel on the same screen: folding
    /// makes it smaller, never absent.
    private func layoutRecording(elapsed: TimeInterval) {
        lastElapsed = elapsed
        let collapsed = PlateCollapse.presentation(isRecording: true, userCollapsed: userCollapsed) == .collapsed
        var views: [NSView]
        if collapsed {
            views = [dot, label, iconButton("chevron.down", L10nKey.badgeExpand.text) { [weak self] in self?.setCollapsed(false) }]
            consentButton = nil
        } else {
            views = [dot, label, meBar, themBar, button(L10nKey.badgeStop.text) { [weak self] in self?.onStop?() }]
            if recordingAuto { views.append(button(L10nKey.badgeDontRecord.text) { [weak self] in self?.onDontRecord?() }) }
            let consent = button(L10nKey.badgeCopyConsent.text) { [weak self] in self?.onCopyConsent?() }
            consent.isHidden = !MeetingBadgeModel.showsConsentHint(elapsed: elapsed)
            consentButton = consent
            views.append(consent)
            views.append(iconButton("chevron.up", L10nKey.badgeCollapse.text) { [weak self] in self?.setCollapsed(true) })
        }
        // The panel is sized before the first clock draw: the label must already
        // hold text of its final width, or the stack measures an empty label.
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.stringValue = MeetingBadgeModel.recText(elapsed: Self.widestElapsed, format: L10nKey.badgeRec.text)
        labelWidth.constant = label.intrinsicContentSize.width
        labelWidth.isActive = true
        label.stringValue = MeetingBadgeModel.recText(elapsed: elapsed, format: L10nKey.badgeRec.text)
        layout(views, keepingPlace: panel.isVisible)
        update(elapsed: elapsed, me: 0, them: 0)
    }

    /// Folds the recording plate to its dot and clock, or opens it again. The panel stays on screen either way.
    func setCollapsed(_ collapsed: Bool) {
        guard case .recording? = mode, userCollapsed != collapsed else { return }
        userCollapsed = collapsed
        layoutRecording(elapsed: lastElapsed)
    }

    /// A start that did not become a recording, said on the plate until the user dismisses it (#518). The same panel,
    /// the same Space guarantees as every other content.
    func showError(_ text: String) {
        mode = .failed(text: text)
        userCollapsed = false
        panel.setAccessibilityLabel(text)
        consentButton = nil
        labelWidth.isActive = false
        label.stringValue = text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        layout([label, button(L10nKey.commonOk.text) { [weak self] in self?.hide() }], capLabel: true)
    }

    /// The detected-call question, naming the app (or the site's app — a browser call says "Google Meet").
    /// It never leaves by itself: `hide()` comes from the call ending, Not now, Record, or Don't ask.
    func showPrompt(source: String) {
        guard mode != .prompt(source: source) else { return }
        mode = .prompt(source: source)
        panel.setAccessibilityLabel(L10nKey.badgePrompt.text)
        consentButton = nil
        labelWidth.isActive = false
        let app = CallPolicy.name(for: source)
        label.stringValue = source.isEmpty ? L10nKey.badgePrompt.text : L10nKey.badgePromptCall.text(app)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        var views: [NSView] = [label,
                               button(L10nKey.badgeRecord.text) { [weak self] in self?.onRecord?() },
                               button(L10nKey.badgeNotNow.text) { [weak self] in self?.onNotNow?() }]
        if !source.isEmpty {
            views.append(quietButton(L10nKey.badgeDontAsk.text(app)) { [weak self] in self?.onDontAsk?() })
        }
        layout(views)
    }

    /// Record was pressed and the call is being re-read (a browser's tabs take up to ~1.5 s): the same prompt,
    /// its buttons disabled so a second press cannot start a second check. No focus change.
    func showRecordChecking(source: String) {
        guard mode != .recordChecking(source: source) else { return }
        mode = .recordChecking(source: source)
        consentButton = nil
        labelWidth.isActive = false
        let app = CallPolicy.name(for: source)
        label.stringValue = source.isEmpty ? L10nKey.badgePrompt.text : L10nKey.badgePromptCall.text(app)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let record = button(L10nKey.badgeRecord.text) {}
        let notNow = button(L10nKey.badgeNotNow.text) {}
        record.isEnabled = false
        notNow.isEnabled = false
        layout([label, record, notNow])
    }

    /// "The call may have ended. Record anyway?" with Record / Cancel, on the badge: a modal alert mid-call
    /// would take the call window's focus. Record is the offered start, Cancel returns to the prompt.
    func showRecordConfirm(source: String) {
        guard mode != .recordConfirm(source: source) else { return }
        mode = .recordConfirm(source: source)
        panel.setAccessibilityLabel(L10nKey.meetingRecordMayHaveEnded.text)
        consentButton = nil
        labelWidth.isActive = false
        label.stringValue = L10nKey.meetingRecordMayHaveEnded.text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        layout([label,
                button(L10nKey.badgeRecord.text) { [weak self] in self?.onConfirmRecord?() },
                button(L10nKey.commonCancel.text) { [weak self] in self?.onConfirmCancel?() }])
    }

    /// The Automation-consent question before the first Apple Event to a browser (`browser` is its bundle id):
    /// Allow… lets the real read raise macOS's own prompt here, Not now sends nothing until the mic is released.
    func showBrowserConsent(browser id: String) {
        guard mode != .browserConsent(browser: id) else { return }
        mode = .browserConsent(browser: id)
        panel.setAccessibilityLabel(L10nKey.badgeBrowserConsent.text(CallDetector.browserName(id)))
        consentButton = nil
        labelWidth.isActive = false
        label.stringValue = L10nKey.badgeBrowserConsent.text(CallDetector.browserName(id))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        layout([label,
                button(L10nKey.badgeBrowserAllow.text) { [weak self] in self?.onBrowserAllow?() },
                button(L10nKey.badgeNotNow.text) { [weak self] in self?.onBrowserNotNow?() }])
    }

    /// Redraws the clock and levels while recording.
    func update(elapsed: TimeInterval, me: Float, them: Float) {
        guard case .recording? = mode else { return }
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.stringValue = MeetingBadgeModel.recText(elapsed: elapsed, format: L10nKey.badgeRec.text)
        meBar.doubleValue = Double(min(1, me * 8))
        themBar.doubleValue = Double(min(1, them * 8))
        var changed = false
        let textWidth = label.intrinsicContentSize.width
        if textWidth > labelWidth.constant {
            labelWidth.constant = textWidth
            changed = true
        }
        // The consent button is a reminder for the first seconds only.
        if let consent = consentButton {
            let hidden = !MeetingBadgeModel.showsConsentHint(elapsed: elapsed)
            if consent.isHidden != hidden {
                consent.isHidden = hidden
                changed = true
            }
        }
        if changed { resize(keepingPlace: true) }
    }

    func hide() {
        mode = nil
        consentButton = nil
        userCollapsed = false
        panel.orderOut(nil)
        watch = PlateWatch()
        PlatePolicyHold.shared.set("meeting", held: false)
    }

    /// The window server's truth about the plate, asked every few seconds while it is up (the user changes Space after
    /// it was shown, which is when #517 hid it): a plate that should be up and is not is logged at fault and escalated
    /// by `PlateWatch`: ordered front again, then the app held `.accessory`, which is what lets a panel join another
    /// app's full-screen Space; if it is still not there, `onNotVisible` tells the user another way.
    func verifyOnScreen() {
        guard mode != nil, panel.isVisible, Date().timeIntervalSince(lastVerified) >= Self.verifyEvery else { return }
        lastVerified = Date()
        let state = PlateProbe.state(panel)
        let policy = PlateProbe.policy()
        let detail = "onscreen=\(state.onscreen) alpha=\(state.alpha) policy=\(policy) mode=\(Self.modeName(mode))"
        for action in watch.observe(onscreen: state.onscreen && state.alpha >= 1, expected: PlateProbe.expectsOnscreen(panel), policy: policy) {
            switch action {
            case .log(.missed(let n)): badgeLog.fault("plate not visible misses=\(n, privacy: .public) \(detail, privacy: .public)")
            case .log(.recovered): badgeLog.notice("plate visible again \(detail, privacy: .public)")
            case .reorder: panel.orderFrontRegardless()
            case .holdAccessory:
                badgeLog.notice("plate held on .accessory policy")
                PlatePolicyHold.shared.set("meeting", held: true)
                panel.orderFrontRegardless()
            case .tell: onNotVisible?()
            }
        }
    }

    private static func modeName(_ mode: Mode?) -> String {
        switch mode {
        case .recording?: return "recording"
        case .prompt?: return "prompt"
        case .recordChecking?: return "record_checking"
        case .recordConfirm?: return "record_confirm"
        case .browserConsent?: return "browser_consent"
        case .failed?: return "failed"
        case nil: return "none"
        }
    }
}
