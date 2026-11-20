import AppKit

/// The cue card («Шпаргалка»): notes the user wants in front of them during a call.
/// The text lives in defaults under one key, the frame per display UUID the way the
/// plate remembers its spot (`BadgePositions`).
public enum CueCardStore {
    /// One defaults key for the whole note text.
    public static let textKey = "cuecard.text"
    /// The most the card holds. The Settings editor shows `cuecard.limit` while the text
    /// sits at the cap — `cap` cutting a paste there is not a silent truncation.
    public static let textLimit = 20_000

    public static func text(_ d: UserDefaults) -> String { d.string(forKey: textKey) ?? "" }

    /// The cap enforced at the store, so any writer (editor, paste, insert) is cut the same way.
    public static func setText(_ text: String, _ d: UserDefaults) { d.set(cap(text), forKey: textKey) }

    public static func cap(_ text: String) -> String { String(text.prefix(textLimit)) }

    /// The recording-notice line at the end of the notes: on its own line when notes exist,
    /// alone in an empty card. The result obeys the cap like any other text.
    public static func consentAppended(to text: String, line: String) -> String {
        guard !text.isEmpty else { return line }
        return cap(text + (text.hasSuffix("\n") ? "" : "\n") + line)
    }

    /// The body text size, as a step: the card's smaller and larger buttons move it.
    public static let textStepKey = "cuecard.textStep"
    public static let textSizes: [CGFloat] = [13, 15, 17, 20]
    public static let defaultTextStep = 1

    public static func textStep(_ d: UserDefaults) -> Int {
        clampStep((d.object(forKey: textStepKey) as? Int) ?? defaultTextStep)
    }

    public static func setTextStep(_ step: Int, _ d: UserDefaults) { d.set(clampStep(step), forKey: textStepKey) }

    static func clampStep(_ step: Int) -> Int { min(max(step, 0), textSizes.count - 1) }

    /// «Фон шпаргалки»: how strongly the material behind the text is drawn. Only the material fades; the text and the
    /// buttons stay at full strength.
    public static let backgroundKey = "cuecard.backgroundAlpha"
    public static let backgroundRange: ClosedRange<Double> = 0.4...1.0

    public static func background(_ d: UserDefaults) -> Double {
        clampBackground((d.object(forKey: backgroundKey) as? Double) ?? backgroundRange.upperBound)
    }

    public static func setBackground(_ value: Double, _ d: UserDefaults) { d.set(clampBackground(value), forKey: backgroundKey) }

    static func clampBackground(_ value: Double) -> Double {
        min(max(value, backgroundRange.lowerBound), backgroundRange.upperBound)
    }

    /// What the material is drawn at. With Reduce Transparency on, macOS draws the material as an opaque fill and the
    /// slider stands down: a faded opaque fill would let the document behind show through again.
    public static func materialAlpha(stored: Double, reduceTransparency: Bool) -> Double {
        reduceTransparency ? backgroundRange.upperBound : clampBackground(stored)
    }
}

/// The card's frame, remembered per display UUID: one defaults key holding a
/// `[displayKey: [x, y, width, height]]` dictionary — the shape `BadgePositions` uses.
public enum CueCardFrames {
    public static let key = "cuecard.frames"

    public static func load(_ d: UserDefaults) -> [String: [Double]] {
        (d.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
    }

    public static func frame(for displayKey: String, _ d: UserDefaults) -> NSRect? {
        guard let v = load(d)[displayKey], v.count == 4 else { return nil }
        return NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    public static func save(_ frame: NSRect, for displayKey: String, _ d: UserDefaults) {
        var all = load(d)
        all[displayKey] = [frame.origin.x, frame.origin.y, frame.width, frame.height]
        d.set(all, forKey: key)
    }
}

/// Where the card goes on a display and how big it may be. Pure, so it is tested without a panel.
public enum CueCardPlacement {
    public static let defaultSize = NSSize(width: 380, height: 260)
    public static let minSize = NSSize(width: 280, height: 120)
    public static let maxWidth: CGFloat = 560
    /// The tallest the card gets, as a share of the display's usable height.
    public static let maxHeightShare: CGFloat = 0.7
    /// The default card's top edge sits this far under the top of the usable area, clear of the plate's row.
    public static let topGap: CGFloat = 56
    /// The header row: what a collapsed card folds to.
    public static let headerHeight: CGFloat = 28
    /// How much of a remembered frame must still be visible to be taken back.
    static let minimumOverlap = 60.0

    public static func maxSize(on visible: NSRect) -> NSSize {
        NSSize(width: maxWidth, height: max(minSize.height, (visible.height * maxHeightShare).rounded(.down)))
    }

    /// The remembered frame when it still overlaps the screen enough, else the default place: top-centre, under the
    /// plate, so the reading eye line stays near the camera.
    public static func frame(saved: NSRect?, on visible: NSRect) -> NSRect {
        guard let saved else { return topCentre(on: visible) }
        let onScreen = saved.intersection(visible)
        guard onScreen.width >= minimumOverlap, onScreen.height >= minimumOverlap else { return topCentre(on: visible) }
        return saved
    }

    static func topCentre(on visible: NSRect) -> NSRect {
        let size = NSSize(width: min(defaultSize.width, visible.width - 40),
                          height: min(defaultSize.height, visible.height - topGap - 20))
        return NSRect(origin: NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.maxY - topGap - size.height),
                      size: size)
    }

    /// Folding keeps the top-left corner: the strip is the header row, as wide as the card.
    public static func collapsed(from frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - headerHeight, width: frame.width, height: headerHeight)
    }

    /// Unfolding restores the earlier size under the strip's current top-left corner (the strip may have been dragged).
    public static func expanded(strip: NSRect, size: NSSize) -> NSRect {
        NSRect(x: strip.minX, y: strip.maxY - size.height, width: size.width, height: size.height)
    }
}

/// Owns the card's one panel: the toggle the global key and the status-menu row share, and the show that Settings'
/// «Показать шпаргалку» calls.
@MainActor
public final class CueCard: NSObject {
    /// What the empty card's button runs; the app points it at the Settings section.
    public var onOpenEditor: (() -> Void)?
    private let defaults: UserDefaults
    /// How the panel goes on and off the screen. The app orders the real window; a test records the calls instead, so
    /// nothing is drawn on the screen of the person running it.
    private let present: (NSPanel) -> Void
    private let dismiss: (NSPanel) -> Void
    /// The display a moved or resized panel is filed under: the UUID of the screen it is on. A test names one, so the
    /// remembering runs the same with no screen attached.
    private let displayKey: (NSPanel) -> String?
    private(set) var panel: CueCardPanel?
    private var observers: [NSObjectProtocol] = []
    /// True while the card itself moves or resizes the panel, so only the user's drags and resizes are remembered.
    private var isPlacing = false
    /// The size to come back to after a fold; nil while the card is unfolded.
    private var unfoldedSize: NSSize?
    /// Whether the card is on screen.
    public private(set) var isShown = false

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, present: { $0.orderFrontRegardless() }, dismiss: { $0.orderOut(nil) })
    }

    init(defaults: UserDefaults, present: @escaping (NSPanel) -> Void, dismiss: @escaping (NSPanel) -> Void,
         displayKey: @escaping (NSPanel) -> String? = { ($0.screen ?? NSScreen.main).flatMap(PlateDisplay.key) }) {
        self.defaults = defaults
        self.present = present
        self.dismiss = dismiss
        self.displayKey = displayKey
        super.init()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// The global key and the status-menu row both call this — one method to mutate.
    public func toggle() {
        if isShown { hide() } else { show() }
    }

    public func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fold lasts until the card is hidden: every show opens the whole card, at the top of the notes.
        if unfoldedSize != nil { setCollapsed(false) }
        refresh()
        place(panel)
        panel.card.scrollToTop()
        // Re-applying the spec at every show picks up a hide-from-share flip made while hidden.
        PlateWindowSpec.apply(to: panel)
        present(panel)
        isShown = true
    }

    /// The close button and the key both land here: the text, the frame and the text size stay.
    public func hide() {
        if let panel { dismiss(panel) }
        isShown = false
    }

    /// The notes, the text size or the background changed: the card on screen shows them in place. The views are the
    /// same ones before and after; nothing is rebuilt per keystroke.
    public func refresh() {
        guard let panel else { return }
        let step = CueCardStore.textStep(defaults)
        panel.card.show(text: CueCardStore.text(defaults), size: CueCardStore.textSizes[step],
                        canShrink: step > 0, canGrow: step < CueCardStore.textSizes.count - 1)
        panel.card.setMaterialAlpha(CueCardStore.materialAlpha(
            stored: CueCardStore.background(defaults),
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency))
    }

    /// The header's smaller and larger buttons.
    func changeTextStep(by delta: Int) {
        CueCardStore.setTextStep(CueCardStore.textStep(defaults) + delta, defaults)
        refresh()
    }

    /// Folds the card to its header row at the same top-left corner, or unfolds it to the size it had. The body keeps
    /// its scroll position across the fold.
    func setCollapsed(_ collapsed: Bool) {
        guard let panel, collapsed == (unfoldedSize == nil) else { return }
        isPlacing = true
        defer { isPlacing = false }
        if collapsed {
            unfoldedSize = panel.frame.size
            panel.card.setCollapsed(true)
            panel.contentMinSize = NSSize(width: CueCardPlacement.minSize.width, height: CueCardPlacement.headerHeight)
            panel.contentMaxSize = NSSize(width: CueCardPlacement.maxWidth, height: CueCardPlacement.headerHeight)
            panel.setFrame(CueCardPlacement.collapsed(from: panel.frame), display: true)
        } else {
            let size = unfoldedSize ?? CueCardPlacement.defaultSize
            unfoldedSize = nil
            panel.card.setCollapsed(false)
            panel.contentMinSize = CueCardPlacement.minSize
            panel.contentMaxSize = (panel.screen ?? NSScreen.main).map { CueCardPlacement.maxSize(on: $0.visibleFrame) }
                ?? NSSize(width: CueCardPlacement.maxWidth, height: CGFloat.greatestFiniteMagnitude)
            panel.setFrame(CueCardPlacement.expanded(strip: panel.frame, size: size), display: true)
        }
    }

    var isCollapsed: Bool { unfoldedSize != nil }

    private func makePanel() -> CueCardPanel {
        let panel = CueCardPanel()
        let card = panel.card
        card.onSmaller = { [weak self] in self?.changeTextStep(by: -1) }
        card.onLarger = { [weak self] in self?.changeTextStep(by: 1) }
        card.onCollapse = { [weak self] in
            guard let self else { return }
            self.setCollapsed(!self.isCollapsed)
        }
        card.onClose = { [weak self] in self?.hide() }
        card.onOpenEditor = { [weak self] in self?.openEditor() }
        let centre = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(centre.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rememberFrame() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        return panel
    }

    /// The remembered frame for the display the card opens on (the one with the keyboard focus); none remembered, or
    /// one dragged mostly off that display since, falls back to the default place.
    private func place(_ panel: CueCardPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.contentMaxSize = CueCardPlacement.maxSize(on: visible)
        let saved = PlateDisplay.key(screen).flatMap { CueCardFrames.frame(for: $0, defaults) }
        isPlacing = true
        panel.setFrame(CueCardPlacement.frame(saved: saved, on: visible), display: true)
        isPlacing = false
    }

    /// The display under the panel after the user's drag or resize owns the remembered frame: moving the card to
    /// another screen files it under that screen's UUID. A folded card is filed at its unfolded size.
    private func rememberFrame() {
        guard !isPlacing, let panel, let key = displayKey(panel) else { return }
        let frame = unfoldedSize.map { CueCardPlacement.expanded(strip: panel.frame, size: $0) } ?? panel.frame
        CueCardFrames.save(frame, for: key, defaults)
    }

    /// The empty card's button: hides the card and opens the main window on Settings.
    private func openEditor() {
        hide()
        onOpenEditor?()
    }
}
