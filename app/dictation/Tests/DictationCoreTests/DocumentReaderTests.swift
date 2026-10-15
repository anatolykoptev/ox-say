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

    func testHtmlIsReadAsTextWithoutScriptsStylesOrImages() async throws {
        let html = """
        <html><head><title>T</title><style>p { color: red }</style><script>var a = "[pause]";</script></head>
        <body><h1>Heading</h1><p>First <b>bold</b> paragraph.</p><img src="http://127.0.0.1:9/x.png" alt="ALT NOISE">
        <script>alert("no")</script><p>Second &amp; last.</p></body></html>
        """
        let url = try write(Data(html.utf8), as: "a.html")
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertScript(url, "Heading\n\nFirst bold paragraph.\n\nSecond & last.")
    }

    func testAWebArchiveIsReadFromItsMainPage() async throws {
        let page = Data("<html><body><p>Archived text.</p></body></html>".utf8)
        let plist: [String: Any] = ["WebMainResource": ["WebResourceData": page, "WebResourceMIMEType": "text/html"]]
        let archive = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let url = try write(archive, as: "a.webarchive")
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertScript(url, "Archived text.")
    }

    func testPlainTextIsReadInUtf8AndWindows1251() async throws {
        let utf8 = try write(Data("Привет.".utf8), as: "a.txt")
        let cp1251 = try write("Привет, как дела? Всё хорошо.".data(using: .windowsCP1251)!, as: "b.md")
        defer { [utf8, cp1251].forEach { try? FileManager.default.removeItem(at: $0) } }
        try await assertScript(utf8, "Привет.")
        try await assertScript(cp1251, "Привет, как дела? Всё хорошо.")
    }

    func testAPdfIsReadPageByPage() async throws {
        let url = try write(pdfData(pages: ["First page text.", "Second page text."]), as: "a.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentReader.read(url)
        XCTAssertEqual(document.source, .pdf)
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertEqual(document.script, "First page text.\n\nSecond page text.")
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
                       ["txt", "md", "markdown", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "pdf"])
    }
}
