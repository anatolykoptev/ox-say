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

    /// Why there is nothing to read, in plain words, when the script is empty. Text
    /// that was there and was all layout is not a scan, and is not said to be.
    public var emptyMessage: String {
        let hadText = pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let kind = source == .pdf ? "PDF" : "document"
        if hadText { return "ox-say could not find readable text in this \(kind) after cleaning it up." }
        return source == .pdf ? "This PDF has no text to read (it may be a scan)." : "This document has no text to read."
    }
}

public enum DocumentError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case unreadable
    case passwordProtected
    case unknownEncoding

    public var description: String {
        switch self {
        case .unsupported(let ext) where ext.lowercased() == "pages":
            return "Pages files can't be read directly. In Pages choose File > Export To > Word or PDF, then open that file."
        case .unsupported:
            return "ox-say reads text, Markdown, Word, RTF, OpenDocument and PDF files."
        case .unreadable:
            return "The file could not be opened. It may be damaged, or not the kind of file its name says."
        case .passwordProtected:
            return "This PDF is protected by a password. Save a copy without the password and open that."
        case .unknownEncoding:
            return "ox-say could not tell how the characters in this file are stored. Save it as UTF-8 text and open it again."
        }
    }
}

/// Reads the text of a document with what macOS ships: AppKit's text importers
/// for Word and friends, PDFKit for PDF. No network, no other dependency.
public enum DocumentReader {
    private enum Kind {
        case text
        case markdown
        case pdf
        case attributed(NSAttributedString.DocumentType)
    }

    private static let kinds: [(ext: String, kind: Kind)] = [
        ("txt", .text), ("md", .markdown), ("markdown", .markdown),
        ("docx", .attributed(.officeOpenXML)), ("doc", .attributed(.docFormat)),
        ("rtf", .attributed(.rtf)), ("rtfd", .attributed(.rtfd)), ("odt", .attributed(.openDocument)),
        ("pdf", .pdf),
    ]

    /// The file extensions the open panel offers.
    public static let supportedExtensions = kinds.map(\.ext)

    public static func read(_ url: URL) async throws -> ReadDocument {
        let ext = url.pathExtension.lowercased()
        guard let kind = kinds.first(where: { $0.ext == ext })?.kind else { throw DocumentError.unsupported(ext) }
        switch kind {
        case .text: return ReadDocument(pages: [try plainText(url)], source: .text)
        case .markdown: return ReadDocument(pages: [try plainText(url)], source: .markdown)
        case .pdf: return ReadDocument(pages: try pdfPages(url), source: .pdf)
        case .attributed(let type): return ReadDocument(pages: [try attributedText(url, type)], source: .richText)
        }
    }

    // MARK: formats

    private static func plainText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw DocumentError.unreadable }
        return try decode(data)
    }

    /// UTF-16 with no byte order mark has a NUL in every other byte of Latin text
    /// and of the spaces and digits between Russian words; at least this share of
    /// the bytes, nearly all on one parity, is that pattern. Text in any other
    /// encoding has no NULs.
    static let utf16NulShare = 0.05
    static let utf16ParityShare = 0.95
    /// Bytes that are not UTF-8 in a file that is UTF-8: a cut-off last character,
    /// a stray byte from a paste. The file is UTF-8 when they are at most this
    /// share of its non-ASCII content (valid non-ASCII characters plus them). Text
    /// in an 8-bit encoding (Windows-1251, Windows-1252) has almost no valid
    /// multi-byte sequences, so its share is near 1; 0.1 separates the two by a
    /// wide margin. A few-character file where one cut byte is more than a tenth of
    /// the non-ASCII content is guessed instead.
    static let maxInvalidShareOfUtf8 = 0.1

    /// The characters of a text file. A byte order mark or the NUL pattern says
    /// UTF-16; bytes that are valid or nearly valid UTF-8 are read as UTF-8 (the
    /// few bad ones become U+FFFD); the rest is guessed by macOS between Windows-1252
    /// (Western) and Windows-1251 (Russian, Ukrainian). Not recognised, and shown
    /// wrongly in the review sheet: KOI8-R, CP866, Windows-1250 and the other 8-bit
    /// encodings, and UTF-16 with neither a mark nor a space or Latin letter in it.
    static func decode(_ data: Data) throws -> String {
        if let bomText = utf16WithMark(data) { return bomText }
        if let text = utf16WithoutMark(data) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        let lossy = String(decoding: data, as: UTF8.self)
        if mostlyUtf8(lossy) { return lossy }
        var converted: NSString?
        _ = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue,
                                                                                          String.Encoding.windowsCP1251.rawValue]],
                                    convertedString: &converted, usedLossyConversion: nil)
        guard let guessed = converted as String?, !guessed.unicodeScalars.contains("\u{0}") else { throw DocumentError.unknownEncoding }
        return guessed
    }

    private static func utf16WithMark(_ data: Data) -> String? {
        let marks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF]]
        guard marks.contains(where: { data.starts(with: $0) }) else { return nil }
        return String(data: data, encoding: .utf16)
    }

    private static func utf16WithoutMark(_ data: Data) -> String? {
        var nulsAt = [0, 0]
        for (index, byte) in data.enumerated() where byte == 0 { nulsAt[index % 2] += 1 }
        let nuls = nulsAt[0] + nulsAt[1]
        guard nuls > 0, Double(nuls) >= Double(data.count) * utf16NulShare,
              Double(max(nulsAt[0], nulsAt[1])) >= Double(nuls) * utf16ParityShare else { return nil }
        // Latin text in UTF-16LE has its NULs in the odd bytes, in UTF-16BE in the even ones.
        return String(data: data, encoding: nulsAt[1] > nulsAt[0] ? .utf16LittleEndian : .utf16BigEndian)
    }

    /// `lossy` is bytes read as UTF-8 with U+FFFD for each bad byte.
    private static func mostlyUtf8(_ lossy: String) -> Bool {
        var invalid = 0, valid = 0
        for scalar in lossy.unicodeScalars {
            if scalar == "\u{FFFD}" { invalid += 1 } else if scalar.value > 0x7F { valid += 1 }
        }
        return Double(invalid) <= Double(invalid + valid) * maxInvalidShareOfUtf8
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
}
