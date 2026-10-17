import AppKit
import DictationCore
import UniformTypeIdentifiers

/// The dialogs of the Studio flows: a file chooser and an alert with form
/// fields. They only collect what the person typed; what is valid is decided in
/// DictationCore (DesignForm, ProduceRequest).
enum StudioForms {
    static let fieldWidth: CGFloat = 340
    static let descriptionHeight: CGFloat = 64
    static let stackSpacing: CGFloat = 6

    struct VoiceDesign {
        var description: String
        var sentence: String
        var name: String
    }

    /// A text, Markdown, Word, RTF, OpenDocument or PDF file, or nil when the
    /// person cancels. The Reel window passes its own localized title/message.
    static func chooseDocument(title: String = "Choose the document to voice",
                               message: String = "Choose a text, Markdown, Word, PDF, RTF or OpenDocument file.") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = DocumentReader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
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

    static func labeled(_ label: String, _ field: NSView, width: CGFloat = fieldWidth) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
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
