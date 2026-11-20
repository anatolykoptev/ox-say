import AppKit

/// The floating card, built like the meeting plate: a borderless non-activating panel that never becomes key, so the
/// call app keeps the typing focus and every button fires on the first click; the plate's material behind the text;
/// dragged by any part that is not a button; resized from its edges. Every window-level decision (level, all Spaces,
/// hide-from-share) goes through `PlateWindowSpec.apply`, as for the plate and the pill. Always dark, like the pill.
public final class CueCardPanel: NSPanel {
    /// The card's content: material, header row, body.
    let card: CueCardView

    public init() {
        card = CueCardView(frame: NSRect(origin: .zero, size: CueCardPlacement.defaultSize))
        super.init(contentRect: NSRect(origin: .zero, size: CueCardPlacement.defaultSize),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
        PlateWindowSpec.apply(to: self)
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .vibrantDark)
        contentMinSize = CueCardPlacement.minSize
        contentView = card
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// The card's content view. The material is the bottom layer; the header and the body are its siblings above it, so
/// «Фон шпаргалки» fades the material only and never the text or the buttons.
final class CueCardView: NSView {
    let material = NSVisualEffectView()
    let title = NSTextField(labelWithString: L10nKey.cueCardSection.text)
    private(set) var smaller: NSButton!
    private(set) var larger: NSButton!
    private(set) var collapse: NSButton!
    private(set) var close: NSButton!
    private(set) var emptyButton: NSButton!
    let scroll = NSScrollView()
    let text = CueCardTextView(frame: .zero)
    let empty = NSStackView()

    var onSmaller: (() -> Void)?
    var onLarger: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenEditor: (() -> Void)?

    /// What the body shows now, so an unchanged text is not laid out again.
    private var shown: (text: String, size: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]

        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        let header = makeHeader()
        configureBody()
        emptyButton = PlateControls.button(L10nKey.cueCardEmptyOpen.text) { [weak self] in self?.onOpenEditor?() }
        let emptyLabel = NSTextField(labelWithString: L10nKey.cueCardEmpty.text)
        emptyLabel.textColor = .secondaryLabelColor
        empty.orientation = .vertical
        empty.spacing = 10
        empty.setViews([emptyLabel, emptyButton], in: .center)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: CueCardPlacement.headerHeight),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The panel is never key; the first click on it must still act (a button) or start a drag (anywhere else).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Title, then smaller, larger, fold and close: the plate's symbol buttons, each with a 24 pt target.
    private func makeHeader() -> NSStackView {
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        // The title takes the spare width, so the buttons sit at the right edge.
        title.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        smaller = PlateControls.iconButton("textformat.size.smaller", L10nKey.cueCardSmaller.text) { [weak self] in self?.onSmaller?() }
        larger = PlateControls.iconButton("textformat.size.larger", L10nKey.cueCardLarger.text) { [weak self] in self?.onLarger?() }
        collapse = PlateControls.iconButton("chevron.up", L10nKey.cueCardCollapse.text) { [weak self] in self?.onCollapse?() }
        close = PlateControls.iconButton("xmark", L10nKey.cueCardClose.text) { [weak self] in self?.onClose?() }
        let header = NSStackView(views: [title, smaller, larger, collapse, close])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 4
        // 24 pt targets in a 28 pt row leave 2 pt above and below.
        header.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 8)
        for button in [smaller, larger, collapse, close] as [NSButton] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        return header
    }

    /// A read-only text view in a scroll view with overlay scrollers. Not selectable: the whole body is a drag area.
    private func configureBody() {
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 14, height: 10)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
    }

    /// The notes in place, or the empty state; the smaller and larger buttons go grey at the ends of the range.
    func show(text value: String, size: CGFloat, canShrink: Bool, canGrow: Bool) {
        let isEmpty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        empty.isHidden = !isEmpty || isCollapsed
        scroll.isHidden = isEmpty || isCollapsed
        smaller.isEnabled = canShrink
        larger.isEnabled = canGrow
        if shown?.text != value || shown?.size != size {
            shown = (value, size)
            text.textStorage?.setAttributedString(CueCardText.render(value, size: size))
        }
    }

    func setMaterialAlpha(_ alpha: Double) { material.alphaValue = CGFloat(alpha) }

    private(set) var isCollapsed = false

    /// Folded, only the header row is left; the body keeps its scroll position for the unfold.
    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        let label = collapsed ? L10nKey.cueCardExpand.text : L10nKey.cueCardCollapse.text
        collapse.image = NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up", accessibilityDescription: label)
        collapse.toolTip = label
        collapse.setAccessibilityLabel(label)
        let isEmpty = (shown?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        scroll.isHidden = collapsed || isEmpty
        empty.isHidden = collapsed || !isEmpty
    }

    func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// The body's text view: read-only, and a mouse-down on it moves the window like the rest of the card.
final class CueCardTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The notes as the card draws them. Inline Markdown (bold, italic, code, links) through Foundation's own parser, line
/// breaks kept as typed; a line that starts with `#` is a heading, drawn semibold without its marker. Lists stay as
/// typed. A line the parser refuses is shown as plain text.
enum CueCardText {
    static func render(_ text: String, size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
            if let heading = headingText(line) {
                out.append(inline(heading, size: size, weight: .semibold))
            } else {
                out.append(inline(line, size: size, weight: .regular))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let all = NSRange(location: 0, length: out.length)
        out.addAttributes([.paragraphStyle: paragraph, .shadow: shadow, .foregroundColor: NSColor.labelColor], range: all)
        return out
    }

    /// `# Title` … `###### Title`: the words after the marker. `#tag` (no space) is not a heading.
    static func headingText(_ line: String) -> String? {
        let marks = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(marks) else { return nil }
        let rest = line.dropFirst(marks)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func inline(_ line: String, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: line, options: options) else {
            return NSAttributedString(string: line, attributes: [.font: base])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [.font: font(base, size: size, weight: weight, intent: intent)]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    private static func font(_ base: NSFont, size: CGFloat, weight: NSFont.Weight, intent: InlinePresentationIntent) -> NSFont {
        if intent.contains(.code) { return .monospacedSystemFont(ofSize: size * 0.92, weight: weight) }
        var font = intent.contains(.stronglyEmphasized) ? NSFont.systemFont(ofSize: size, weight: .bold) : base
        if intent.contains(.emphasized) {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        return font
    }
}
