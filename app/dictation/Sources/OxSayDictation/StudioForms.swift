import AppKit
import DictationCore
import UniformTypeIdentifiers

/// The dialogs of the Studio flows: a file chooser and two alerts with form
/// fields. They only collect what the person typed; what is valid is decided in
/// DictationCore (DesignForm, ProduceRequest).
enum StudioForms {
    static let fieldWidth: CGFloat = 340
    static let descriptionHeight: CGFloat = 64
    static let stackSpacing: CGFloat = 6

    struct VoiceoverChoice {
        var title: String
        var format: ProduceFormat
        var voice: String?
    }

    struct VoiceDesign {
        var description: String
        var sentence: String
        var name: String
    }

    /// A plain text or Markdown file, or nil when the person cancels.
    static func chooseTextFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the text to voice"
        panel.message = "Choose a text or Markdown file."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")].compactMap { $0 }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Title, Format and Voice; nil when cancelled.
    static func voiceoverForm(defaultTitle: String, choices: (names: [String?], selected: Int)) -> VoiceoverChoice? {
        let title = NSTextField(string: defaultTitle)
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: ProduceFormat.allCases.map(\.title))
        let voice = NSPopUpButton(frame: .zero, pullsDown: false)
        voice.addItems(withTitles: choices.names.map { $0 ?? "Default voice" })
        voice.selectItem(at: choices.selected)

        let alert = NSAlert()
        alert.messageText = "New Voiceover"
        alert.informativeText = "ox-say reads the file aloud in the voice you choose."
        alert.accessoryView = stack([labeled("Title", title), labeled("Format", format), labeled("Voice", voice)])
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return VoiceoverChoice(title: title.stringValue, format: ProduceFormat.allCases[format.indexOfSelectedItem],
                               voice: choices.names[voice.indexOfSelectedItem])
    }

    /// The Create a Voice form. A problem with what was typed is said and the
    /// form comes back with the same text; nil when cancelled.
    static func designForm(preset: VoiceDesign) -> VoiceDesign? {
        var values = preset
        while true {
            let description = NSTextField(string: values.description)
            description.placeholderString = DesignForm.descriptionPlaceholder
            description.usesSingleLineMode = false
            description.cell?.wraps = true
            description.cell?.isScrollable = false
            description.lineBreakMode = .byWordWrapping
            description.frame.size = NSSize(width: fieldWidth, height: descriptionHeight)
            let sentence = NSTextField(string: values.sentence)
            let name = NSTextField(string: values.name)
            name.placeholderString = "Optional — ox-say suggests one"

            let alert = NSAlert()
            alert.messageText = "Create a Voice"
            alert.informativeText = "Describe who should speak. ox-say makes three takes to choose from."
            alert.accessoryView = stack([labeled("Describe the voice", description),
                                         labeled("Sample sentence", sentence), labeled("Name", name)])
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            values = VoiceDesign(description: description.stringValue, sentence: sentence.stringValue, name: name.stringValue)
            guard let problem = DesignForm.problem(description: values.description, sentence: values.sentence, name: values.name) else {
                return values
            }
            let notice = NSAlert()
            notice.messageText = "Check the form"
            notice.informativeText = problem
            notice.addButton(withTitle: "OK")
            notice.runModal()
        }
    }

    private static func labeled(_ label: String, _ field: NSView) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        if field.frame.height > 0 {
            field.heightAnchor.constraint(equalToConstant: field.frame.height).isActive = true
        }
        let column = NSStackView(views: [caption, field])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    private static func stack(_ rows: [NSView]) -> NSView {
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = stackSpacing
        column.setFrameSize(column.fittingSize)
        return column
    }
}
