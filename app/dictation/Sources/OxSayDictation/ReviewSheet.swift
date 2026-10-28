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

    /// Starts from inside the editor, where Return types a new line.
    static let startKeyHint = "⌘Return"
    static let editorSize = NSSize(width: 560, height: 300)
    static let editorFontSize: CGFloat = 13
    private static let contentInset: CGFloat = 16
    private static let editorInset = NSSize(width: 4, height: 6)

    private let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let textView: NSTextView
    private let scroll = NSTextView.scrollableTextView()
    private let status = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: L10nKey.reviewStart.text, target: nil, action: nil)
    private let trimButton = NSButton(title: L10nKey.reviewKeepFirst.text, target: nil, action: nil)
    private let titleField: NSTextField
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceNames: [String?]
    private var outcome: Result?
    private var finished = false

    /// The sheet opens on `draft`: the document's first cleaning, or what the person
    /// had when a start was refused. `voiceNames` are the Voice popup's choices (nil is the default voice).
    init(draft: Result, voiceNames: [String?]) {
        textView = scroll.documentView as! NSTextView
        titleField = NSTextField(string: draft.title)
        self.voiceNames = voiceNames
        super.init()
        formatPopup.addItems(withTitles: ProduceFormat.allCases.map { $0.title() })
        formatPopup.selectItem(at: ProduceFormat.allCases.firstIndex(of: draft.format) ?? 0)
        voicePopup.addItems(withTitles: voiceNames.map { $0 ?? L10nKey.voicesDefault.text })
        voicePopup.selectItem(at: voiceNames.firstIndex { $0 == draft.voice } ?? 0)
        configureEditor(draft.script)
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
        panel.title = L10nKey.reviewTitle.text
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = .command
        startButton.toolTip = L10nKey.reviewStartTip.text(Self.startKeyHint)
        startButton.target = self
        startButton.action = #selector(start)
        let cancel = NSButton(title: L10nKey.commonCancel.text, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        trimButton.target = self
        trimButton.action = #selector(keepFirstPart)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [trimButton, spacer, cancel, startButton])
        buttons.orientation = .horizontal
        let form = NSStackView(views: [
            StudioForms.labeled(L10nKey.reviewLabelTitle.text, titleField, width: Self.editorSize.width),
            StudioForms.labeled(L10nKey.reviewLabelFormat.text, formatPopup, width: Self.editorSize.width),
            StudioForms.labeled(L10nKey.menuVoice.text, voicePopup, width: Self.editorSize.width),
            StudioForms.labeled(L10nKey.reviewLabelText.text, scroll, width: Self.editorSize.width),
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
