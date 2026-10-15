import AppKit
import PDFKit
import XCTest
@testable import DictationCore

/// The readers run against files this test writes with the same system frameworks.
final class DocumentReaderTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ox-say-test-\(UUID().uuidString)-\(name)")
    }

    /// Writes `data` as a file called `name`; the caller removes it.
    private func write(_ data: Data, as name: String) throws -> URL {
        let url = tempURL(name)
        try data.write(to: url)
        return url
    }

    private func attributedData(_ text: String, _ type: NSAttributedString.DocumentType) throws -> Data {
        try NSAttributedString(string: text).data(from: NSRange(location: 0, length: (text as NSString).length),
                                                 documentAttributes: [.documentType: type])
    }

    private func pdfData(pages: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text))
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 36, dy: 36), transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func assertScript(_ url: URL, _ expected: String) async throws {
        let got = try await DocumentReader.read(url).script
        XCTAssertEqual(got, expected)
    }

    func testRtfIsRead() async throws {
        let url = try write(attributedData("Привет, мир.\nSecond paragraph.", .rtf), as: "a.rtf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentReader.read(url)
        XCTAssertEqual(document.source, .richText)
        XCTAssertEqual(document.script, "Привет, мир.\n\nSecond paragraph.")
    }

    func testDocxIsRead() async throws {
        let url = try write(attributedData("Первый абзац.\nSecond paragraph.", .officeOpenXML), as: "a.docx")
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertScript(url, "Первый абзац.\n\nSecond paragraph.")
    }

    func testOdtIsRead() async throws {
        let url = try write(attributedData("Open document text.", .openDocument), as: "a.odt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertScript(url, "Open document text.")
    }

    func testPlainTextIsReadInUtf8AndWindows1251() async throws {
        let utf8 = try write(Data("Привет.".utf8), as: "a.txt")
        let cp1251 = try write("Привет, как дела? Всё хорошо.".data(using: .windowsCP1251)!, as: "b.md")
        defer { [utf8, cp1251].forEach { try? FileManager.default.removeItem(at: $0) } }
        try await assertScript(utf8, "Привет.")
        try await assertScript(cp1251, "Привет, как дела? Всё хорошо.")
    }

    func testMarkdownFilesAreReadAsMarkdownAndTextFilesAreNot() async throws {
        let md = try write(Data("A [link](https://x.y/z) here.".utf8), as: "a.md")
        let markdown = try write(Data("A [link](https://x.y/z) here.".utf8), as: "b.markdown")
        let txt = try write(Data("A [link](https://x.y/z) here.".utf8), as: "c.txt")
        defer { [md, markdown, txt].forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in [md, markdown] {
            let document = try await DocumentReader.read(url)
            XCTAssertEqual(document.source, .markdown)
            XCTAssertEqual(document.script, "A link here.")
        }
        let plain = try await DocumentReader.read(txt)
        XCTAssertEqual(plain.source, .text)
        XCTAssertEqual(plain.script, "A link (https://x.y/z) here.")
    }

    func testAPdfIsReadPageByPage() async throws {
        let url = try write(pdfData(pages: ["First page text.", "Second page text."]), as: "a.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentReader.read(url)
        XCTAssertEqual(document.source, .pdf)
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertEqual(document.script, "First page text.\n\nSecond page text.")
    }

    func testAPdfKeepsTheNumberAtTheEdgeOfItsOnlyPageAndDropsRealPageNumbers() async throws {
        let single = try write(pdfData(pages: ["Bake until golden.\nServes\n4"]), as: "single.pdf")
        let numbered = try write(pdfData(pages: (1...5).map { "Leaf \($0) holds some words.\n\($0)" }), as: "numbered.pdf")
        defer { [single, numbered].forEach { try? FileManager.default.removeItem(at: $0) } }
        let kept = try await DocumentReader.read(single).script
        XCTAssertTrue(kept.hasSuffix("Serves 4"), kept)
        let dropped = try await DocumentReader.read(numbered).script
        XCTAssertEqual(dropped.split(whereSeparator: \.isWhitespace).filter { $0.allSatisfy(\.isNumber) }.count, 5,
                       "only the five numbers inside the sentences stay: \(dropped)")
    }

    func testReadScriptIsTheReadAndCleanedDocumentWithItsEmptyMessage() async throws {
        let rtf = try write(attributedData("Привет, мир.\nSecond paragraph.", .rtf), as: "a.rtf")
        let scan = try write(pdfData(pages: [""]), as: "scan.pdf")
        defer { [rtf, scan].forEach { try? FileManager.default.removeItem(at: $0) } }
        let read = try await DocumentReader.readScript(rtf)
        let document = try await DocumentReader.read(rtf)
        XCTAssertEqual(read, ReadScript(script: document.script, emptyMessage: document.emptyMessage))
        XCTAssertEqual(read.script, "Привет, мир.\n\nSecond paragraph.")
        let empty = try await DocumentReader.readScript(scan)
        XCTAssertEqual(empty.script, "")
        XCTAssertEqual(empty.emptyMessage, "This PDF has no text to read (it may be a scan).")
    }

    func testAPdfWithoutATextLayerReadsAsEmptyAndSaysWhy() async throws {
        let size = 64
        let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = NSImage(cgImage: bitmap.makeImage()!, size: NSSize(width: size, height: size))
        let scan = PDFDocument()
        scan.insert(PDFPage(image: image)!, at: 0)
        let url = tempURL("scan.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(scan.write(to: url))
        let document = try await DocumentReader.read(url)
        XCTAssertEqual(document.script, "")
        XCTAssertEqual(document.emptyMessage, "This PDF has no text to read (it may be a scan).")
    }

    func testAPdfWhoseTextIsAllLayoutDoesNotSayItMayBeAScan() {
        let document = ReadDocument(pages: ["1", "2", "3"], source: .pdf)
        XCTAssertEqual(document.script, "")
        XCTAssertEqual(document.emptyMessage, "ox-say could not find readable text in this PDF after cleaning it up.")
        XCTAssertEqual(ReadDocument(pages: ["", "  \n"], source: .pdf).emptyMessage, "This PDF has no text to read (it may be a scan).")
    }

    func testUnsupportedAndBrokenFilesAreSaidInPlainWords() async throws {
        let pages = try write(Data([0x50, 0x4B]), as: "a.pages")
        let broken = try write(Data("not a pdf".utf8), as: "b.pdf")
        defer { [pages, broken].forEach { try? FileManager.default.removeItem(at: $0) } }
        do { _ = try await DocumentReader.read(pages); XCTFail("expected unsupported") } catch {
            XCTAssertEqual(error as? DocumentError, .unsupported("pages"))
            XCTAssertTrue("\(error)".contains("Export To > Word or PDF"))
        }
        do { _ = try await DocumentReader.read(broken); XCTFail("expected unreadable") } catch {
            XCTAssertEqual(error as? DocumentError, .unreadable)
        }
    }

    func testThePanelOffersExactlyTheReadableTypes() {
        XCTAssertEqual(Set(DocumentReader.supportedExtensions),
                       ["txt", "md", "markdown", "docx", "doc", "rtf", "rtfd", "odt", "pdf"])
    }

    // MARK: encodings

    private let russian = "Привет, мир. Это длинный текст для проверки кодировки. "

    func testUtf8CutInTheMiddleOfACharacterIsStillUtf8() throws {
        let long = Data((String(repeating: russian, count: 40) + "т").utf8).dropLast(1)
        let text = try DocumentReader.decode(Data(long))
        XCTAssertTrue(text.hasPrefix("Привет, мир. Это длинный текст"), String(text.prefix(40)))
        XCTAssertEqual(text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count, 1)
        let short = try DocumentReader.decode(Data("Привет мир, длинный текст".utf8).dropLast(1))
        XCTAssertTrue(short.hasPrefix("Привет мир, длинный текс"), short)
    }

    func testAFewStrayBytesInUtf8TextDoNotMakeItAnotherEncoding() throws {
        var data = Data(String(repeating: russian, count: 40).utf8)
        // After a space, so no character is split.
        data.insert(0xFF, at: try XCTUnwrap(data[100...].firstIndex(of: 0x20)) + 1)
        data.insert(0xFE, at: try XCTUnwrap(data[900...].firstIndex(of: 0x20)) + 1)
        let text = try DocumentReader.decode(data)
        XCTAssertEqual(text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count, 2)
        XCTAssertTrue(text.contains("Это длинный текст для проверки кодировки."))
    }

    func testAStrayByteInMostlyAsciiUtf8TextDoesNotTurnItIntoMojibake() throws {
        var data = Data(String(repeating: "The café was open and the naïve fiancé said hello. ", count: 20).utf8)
        data.insert(0xFF, at: try XCTUnwrap(data[200...].firstIndex(of: 0x20)) + 1)
        let text = try DocumentReader.decode(data)
        XCTAssertTrue(text.contains("The café was open and the naïve fiancé said hello."), String(text.prefix(60)))
        XCTAssertEqual(text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count, 1)
    }

    func testEightBitTextWithFewHighBytesIsNotReadAsBrokenUtf8() throws {
        let sentence = "He said it was a fine day, and the café was open. "
        let text = String(repeating: sentence, count: 40) + "She wrote \u{2019}hello\u{2019} \u{201C}twice\u{201D}."
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        let decoded = try DocumentReader.decode(data)
        XCTAssertEqual(decoded, text)
    }

    func testWindows1251IsStillRecognised() throws {
        let data = try XCTUnwrap(String(repeating: russian, count: 5).data(using: .windowsCP1251))
        let decoded = try DocumentReader.decode(data)
        XCTAssertEqual(decoded, String(repeating: russian, count: 5))
    }

    func testUtf16WithoutAByteOrderMarkIsRecognisedByItsNulBytes() throws {
        for text in ["Hello world, this is plain text. ", russian] {
            let little = try DocumentReader.decode(try XCTUnwrap(text.data(using: .utf16LittleEndian)))
            let big = try DocumentReader.decode(try XCTUnwrap(text.data(using: .utf16BigEndian)))
            XCTAssertEqual(little, text)
            XCTAssertEqual(big, text)
        }
    }

    func testUtf16WithAByteOrderMarkIsRead() throws {
        let cyrillic = try DocumentReader.decode(try XCTUnwrap(russian.data(using: .utf16)))
        let latin = try DocumentReader.decode(try XCTUnwrap("Hello".data(using: .utf16)))
        XCTAssertEqual(ScriptCleaner.clean(cyrillic), ScriptCleaner.clean(russian))
        XCTAssertEqual(ScriptCleaner.clean(latin), "Hello")
    }

    func testBinaryDataIsRefusedInPlainWords() async throws {
        let bytes = Data([0x00, 0x01, 0x00, 0x00, 0xFF, 0xD8, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC3, 0x28, 0x00])
        do { _ = try DocumentReader.decode(bytes); XCTFail("expected a refusal") } catch {
            XCTAssertEqual(error as? DocumentError, .unknownEncoding)
            XCTAssertTrue("\(error)".contains("Save it as UTF-8"))
        }
        let url = try write(bytes, as: "a.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await DocumentReader.read(url); XCTFail("expected a refusal") } catch {
            XCTAssertEqual(error as? DocumentError, .unknownEncoding)
        }
    }
}

