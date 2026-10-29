import AppKit
import DictationCore

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
        /// macOS's Automation answer for this browser is undetermined: ask in context before the first Apple Event.
        case browserConsent(browser: String)
    }

    var onStop: (() -> Void)?
    var onDontRecord: (() -> Void)?
    var onRecord: (() -> Void)?
    var onNotNow: (() -> Void)?
    /// "Don't ask for <App>": the prompt's third, quieter action.
    var onDontAsk: (() -> Void)?
    /// The Automation badge's "Allow…": the next tab read raises macOS's prompt in context.
    var onBrowserAllow: (() -> Void)?
    /// The Automation badge's "Not now": no Apple Event until the browser lets the microphone go.
    var onBrowserNotNow: (() -> Void)?
    var onCopyConsent: (() -> Void)?

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

    /// The widest clock the label shows (digits are monospaced): 9:59:59.
    private static let widestElapsed: TimeInterval = 10 * 3600 - 1

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
        dot.setAccessibilityElement(true)
        dot.setAccessibilityRole(.image)
        dot.setAccessibilityLabel(L10nKey.badgeA11yDot.text)
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
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
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

    private static var handlerKey = 0

    private final class ActionTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    private func layout(_ views: [NSView]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        views.forEach { stack.addArrangedSubview($0) }
        resize(keepingPlace: false)
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
        panel.setContentSize(NSSize(width: max(size.width, 220), height: 36))
        place(anchoredOffset: offset, onScreen: keepingPlace ? placedOn : nil)
    }

    /// Puts the panel on a screen that exists now: `BadgePlacement.place` decides which one and where (DictationCore,
    /// table-tested); this reads the screens and moves the window.
    private func place(anchoredOffset: Double?, onScreen: UInt32?) {
        let screens = NSScreen.screens.compactMap { screen -> BadgePlacement.Screen? in
            guard let id = Self.displayID(screen) else { return nil }
            let frame = screen.visibleFrame
            return BadgePlacement.Screen(id: id, minX: Double(frame.minX), maxX: Double(frame.maxX), maxY: Double(frame.maxY))
        }
        // No screens (the lid closed, the display asleep): the badge stays where it is; the next change places it.
        guard let spot = BadgePlacement.place(screens: screens, placedOn: onScreen, main: NSScreen.main.flatMap(Self.displayID),
                                              anchoredOffset: anchoredOffset, width: Double(panel.frame.width),
                                              height: Double(panel.frame.height)) else { return }
        placedOn = spot.screenID
        placedOffset = spot.offset
        panel.setFrameOrigin(NSPoint(x: spot.x, y: spot.y))
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A display was plugged, unplugged or changed its size: a badge that is up (prompt, consent question or recording)
    /// is placed again on a screen that still exists (#342.4). Nothing to do for a badge that is not on screen: its next
    /// content is placed when it appears.
    private func screensChanged() {
        guard panel.isVisible, mode != nil else { return }
        place(anchoredOffset: placedOffset, onScreen: placedOn)
    }

    func showRecording(auto: Bool, elapsed: TimeInterval) {
        guard mode != .recording(auto: auto) else { return }
        mode = .recording(auto: auto)
        panel.setAccessibilityLabel(L10nKey.badgeA11yPanel.text)
        var views: [NSView] = [dot, label, meBar, themBar, button(L10nKey.badgeStop.text) { [weak self] in self?.onStop?() }]
        if auto { views.append(button(L10nKey.badgeDontRecord.text) { [weak self] in self?.onDontRecord?() }) }
        let consent = button(L10nKey.badgeCopyConsent.text) { [weak self] in self?.onCopyConsent?() }
        consent.isHidden = !MeetingBadgeModel.showsConsentHint(elapsed: elapsed)
        consentButton = consent
        views.append(consent)
        // The panel is sized before the first clock draw: the label must already
        // hold text of its final width, or the stack measures an empty label.
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.stringValue = MeetingBadgeModel.recText(elapsed: Self.widestElapsed, format: L10nKey.badgeRec.text)
        labelWidth.constant = label.intrinsicContentSize.width
        labelWidth.isActive = true
        label.stringValue = MeetingBadgeModel.recText(elapsed: elapsed, format: L10nKey.badgeRec.text)
        layout(views)
        update(elapsed: elapsed, me: 0, them: 0)
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
        panel.orderOut(nil)
    }
}
