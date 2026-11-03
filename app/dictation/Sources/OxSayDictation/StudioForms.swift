import AppKit
import DictationCore
import UniformTypeIdentifiers

/// The dialogs of the Studio flows: a file chooser and the labelled-field helper the review sheet lays out with.
/// They only collect what the person typed; what is valid is decided in DictationCore (ProduceRequest).
enum StudioForms {
    static let fieldWidth: CGFloat = 340
    static let stackSpacing: CGFloat = 6

    /// A text, Markdown, Word, RTF, OpenDocument or PDF file, or nil when the person cancels.
    static func chooseDocument() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10nKey.studioChooseTitle.text
        panel.message = L10nKey.studioChooseMessage.text
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = DocumentReader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
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
