import AppKit
import DictationCore

/// The window every document goes through before a voiceover starts: the cleaned
/// text in an editor, Title, Format and Voice, and a live line saying how long the
/// text is. It only collects; what is allowed is decided by ScriptLimit.
final class ReviewSheet: NSObject, NSTextViewDelegate, NSWindowDelegate {
    struct Result {
        var title: String
        var script: String
        var format: ProduceFormat
        var voice: String?
    }

    static let editorSize = NSSize(width: 560, height: 300)
    static let editorFontSize: CGFloat = 13
    private static let contentInset: CGFloat = 16
    private static let editorInset = NSSize(width: 4, height: 6)

    private let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let textView: NSTextView
    private let scroll = NSTextView.scrollableTextView()
    private let status = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let trimButton = NSButton(title: "Keep the First Part", target: nil, action: nil)
    private let titleField: NSTextField
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceNames: [String?]
    private var outcome: Result?
    private var finished = false

    init(defaultTitle: String, text: String, voices: (names: [String?], selected: Int)) {
        textView = scroll.documentView as! NSTextView
        titleField = NSTextField(string: defaultTitle)
        voiceNames = voices.names
        super.init()
        formatPopup.addItems(withTitles: ProduceFormat.allCases.map(\.title))
        voicePopup.addItems(withTitles: voices.names.map { $0 ?? "Default voice" })
        voicePopup.selectItem(at: voices.selected)
        configureEditor(text)
        build()
        refresh()
    }

    /// Shows the sheet and waits; nil when the person cancels.
    func run() -> Result? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        NSApp.runModal(for: panel)
        finished = true
        panel.orderOut(nil)
        return outcome
    }

    // MARK: building

    private func configureEditor(_ text: String) {
        textView.string = text
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: Self.editorFontSize)
        textView.textContainerInset = Self.editorInset
        // What is typed is sent as typed: no curly quotes, no dashes, no corrections.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: Self.editorSize.width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: Self.editorSize.height).isActive = true
    }

    private func build() {
        panel.title = "New Voiceover"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(start)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        trimButton.target = self
        trimButton.action = #selector(keepFirstPart)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [trimButton, spacer, cancel, startButton])
        buttons.orientation = .horizontal
        let form = NSStackView(views: [
            StudioForms.labeled("Title", titleField, width: Self.editorSize.width),
            StudioForms.labeled("Format", formatPopup, width: Self.editorSize.width),
            StudioForms.labeled("Voice", voicePopup, width: Self.editorSize.width),
            StudioForms.labeled("Text — check it and fix anything before ox-say reads it", scroll, width: Self.editorSize.width),
            status, buttons,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = StudioForms.stackSpacing * 2
        form.edgeInsets = NSEdgeInsets(top: Self.contentInset, left: Self.contentInset, bottom: Self.contentInset, right: Self.contentInset)
        buttons.widthAnchor.constraint(equalToConstant: Self.editorSize.width).isActive = true
        panel.contentView = form
        panel.setContentSize(form.fittingSize)
    }

    // MARK: state

    /// The line under the text, Start and Keep the First Part follow what is in the editor now.
    private func refresh() {
        let text = textView.string
        let canStart = ScriptLimit.canStart(editorText: text)
        status.stringValue = ScriptLimit.statusLine(editorText: text)
        status.textColor = canStart ? .secondaryLabelColor : .systemRed
        startButton.isEnabled = canStart
        trimButton.isHidden = ScriptLimit.overBy(ScriptLimit.script(from: text)) == 0
    }

    func textDidChange(_ notification: Notification) {
        refresh()
    }

    @objc private func keepFirstPart() {
        textView.string = ScriptLimit.keepFirstPart(textView.string)
        refresh()
    }

    @objc private func start() {
        outcome = Result(title: titleField.stringValue, script: ScriptLimit.script(from: textView.string),
                         format: ProduceFormat.allCases[formatPopup.indexOfSelectedItem],
                         voice: voiceNames[voicePopup.indexOfSelectedItem])
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel() {
        NSApp.stopModal(withCode: .cancel)
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { NSApp.stopModal(withCode: .cancel) }
    }
}
