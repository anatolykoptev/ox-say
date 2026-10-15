import AppKit
import Foundation
import PDFKit

/// A document's text as read from disk, before ScriptCleaner.
public struct ReadDocument: Equatable {
    /// One text for most formats; one entry per page for a PDF.
    public var pages: [String]
    public var source: ScriptCleaner.Source

    public init(pages: [String], source: ScriptCleaner.Source) {
        self.pages = pages
        self.source = source
    }

    /// The script the review sheet starts from.
    public var script: String { ScriptCleaner.clean(pages: pages, source: source) }

    /// Why there is nothing to read, in plain words, when the script is empty.
    public var emptyMessage: String {
        source == .pdf ? "This PDF has no text to read (it may be a scan)." : "This document has no text to read."
    }
}

public enum DocumentError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case unreadable
    case passwordProtected

    public var description: String {
        switch self {
        case .unsupported(let ext) where ext.lowercased() == "pages":
            return "Pages files can't be read directly. In Pages choose File > Export To > Word or PDF, then open that file."
        case .unsupported:
            return "ox-say reads text, Markdown, Word, RTF, OpenDocument, HTML and PDF files."
        case .unreadable:
            return "The file could not be opened. It may be damaged, or not the kind of file its name says."
        case .passwordProtected:
            return "This PDF is protected by a password. Save a copy without the password and open that."
        }
    }
}

/// Reads the text of a document with what macOS ships: AppKit's text importers
/// for Word and friends, PDFKit for PDF. No network, no other dependency.
public enum DocumentReader {
    private enum Kind {
        case text
        case pdf
        case attributed(NSAttributedString.DocumentType)
        case html
        case webArchive
    }

    private static let kinds: [(ext: String, kind: Kind)] = [
        ("txt", .text), ("md", .text), ("markdown", .text),
        ("docx", .attributed(.officeOpenXML)), ("doc", .attributed(.docFormat)),
        ("rtf", .attributed(.rtf)), ("rtfd", .attributed(.rtfd)), ("odt", .attributed(.openDocument)),
        ("html", .html), ("htm", .html), ("webarchive", .webArchive),
        ("pdf", .pdf),
    ]

    /// The file extensions the open panel offers.
    public static let supportedExtensions = kinds.map(\.ext)

    public static func read(_ url: URL) async throws -> ReadDocument {
        let ext = url.pathExtension.lowercased()
        guard let kind = kinds.first(where: { $0.ext == ext })?.kind else { throw DocumentError.unsupported(ext) }
        switch kind {
        case .text: return ReadDocument(pages: [try plainText(url)], source: .text)
        case .pdf: return ReadDocument(pages: try pdfPages(url), source: .pdf)
        case .attributed(let type): return ReadDocument(pages: [try attributedText(url, type)], source: .richText)
        case .html: return ReadDocument(pages: [try htmlText(try Data(contentsOf: url))], source: .richText)
        case .webArchive: return ReadDocument(pages: [try htmlText(try archiveMainPage(url))], source: .richText)
        }
    }

    // MARK: formats

    private static func plainText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw DocumentError.unreadable }
        return decode(data)
    }

    /// UTF-8 when the bytes are valid UTF-8; otherwise the encoding macOS guesses,
    /// with Windows-1251 (the usual one for Russian text files) as its first suggestion.
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        _ = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [String.Encoding.windowsCP1251.rawValue]],
                                    convertedString: &converted, usedLossyConversion: nil)
        return converted as String? ?? String(decoding: data, as: UTF8.self)
    }

    private static func pdfPages(_ url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else { throw DocumentError.unreadable }
        if document.isLocked { throw DocumentError.passwordProtected }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    private static func attributedText(_ url: URL, _ type: NSAttributedString.DocumentType) throws -> String {
        guard let text = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else {
            throw DocumentError.unreadable
        }
        return text.string
    }

    /// The page of a Safari web archive: the main resource of its property list.
    private static func archiveMainPage(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any],
              let page = main["WebResourceData"] as? Data else { throw DocumentError.unreadable }
        return page
    }

    /// The text of a page, from its parsed tree (see HTMLText): a page cannot make
    /// this Mac load anything.
    private static func htmlText(_ page: Data) throws -> String {
        guard let text = HTMLText.plain(decode(page)) else { throw DocumentError.unreadable }
        return text
    }
}
