import AppKit
import Foundation
import XCTest
@testable import DictationCore

/// A local document must never make this Mac touch the network. The oracle is a
/// real listener on 127.0.0.1: each document below points at it through one way
/// its format can reference something outside the file, and after reading all of
/// them (plus a short wait for a late request) the listener must have seen
/// nobody. Covered: .docx, .odt, .rtf and .rtfd (a package holding the same RTF).
/// Not covered: .doc, whose binary format AppKit writes without any link and which
/// cannot be built by hand here. PDFKit and the plain-text readers read no references.
final class LocalDocumentNetworkTests: XCTestCase {
    /// Time given to a request that was started but not yet sent.
    private static let graceNanoseconds: UInt64 = 600_000_000
    private static let visible = "Visible text."

    private struct Vector {
        var name: String
        /// Markup in the body of the document.
        var body = ""
        /// An ODF content.xml element that comes before the body.
        var head = ""
        /// Relationships of word/document.xml: (id, type, target), all external.
        var relationships: [(id: String, type: String, target: String)] = []
        /// A whole replacement for an extra part (settings.xml, styles.xml, meta.xml) and its relationships.
        var part = ""
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ox-say-net-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    private func assertNeverConnects(_ build: (String) throws -> [(name: String, url: URL)]) async throws {
        let listener = try LoopbackListener()
        defer { listener.stop() }
        let documents = try build(listener.origin)
        defer { documents.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        XCTAssertFalse(documents.isEmpty)
        var lost: [String] = []
        for (name, url) in documents {
            let document = try await DocumentReader.read(url)
            if !document.script.contains(Self.visible) { lost.append(name) }
        }
        try await Task.sleep(nanoseconds: Self.graceNanoseconds)
        XCTAssertEqual(listener.connections, [], "a local file made the Mac open connections")
        XCTAssertEqual(lost, [], "the visible text must survive every document")
    }

    func testTheOracleSeesAConnection() async throws {
        let listener = try LoopbackListener()
        defer { listener.stop() }
        XCTAssertEqual(listener.connections, [])
        let session = URLSession(configuration: .ephemeral)
        _ = try? await session.data(from: URL(string: "\(listener.origin)/probe")!)
        try await Task.sleep(nanoseconds: Self.graceNanoseconds)
        XCTAssertEqual(listener.connections.count, 1)
        XCTAssertTrue(listener.connections.first?.contains("/probe") ?? false, "\(listener.connections)")
    }

    // MARK: .docx

    private static let wordNamespaces = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" \
    xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" \
    xmlns:xlink="http://www.w3.org/1999/xlink"
    """
    private static let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    private func docxVectors(_ origin: String) -> [Vector] {
        func url(_ name: String) -> String { "\(origin)/docx-\(name)" }
        func external(_ type: String, _ name: String) -> [(id: String, type: String, target: String)] {
            [(id: "rId10", type: Self.relationshipType + type, target: url(name))]
        }
        func field(_ name: String, _ code: String) -> String {
            "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> \(code) \"\(url(name))\" </w:instrText></w:r>"
                + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>result</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
        }
        return [
            Vector(name: "external-image", body: "<w:r><w:drawing><wp:inline><wp:extent cx=\"1\" cy=\"1\"/><a:graphic><a:graphicData "
                   + "uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:blipFill><a:blip r:link=\"rId10\"/>"
                   + "</pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>",
                   relationships: external("image", "external-image")),
            Vector(name: "hyperlink", body: "<w:hyperlink r:id=\"rId10\"><w:r><w:t>a link</w:t></w:r></w:hyperlink>",
                   relationships: external("hyperlink", "hyperlink")),
            Vector(name: "includepicture-simple",
                   body: "<w:fldSimple w:instr=\" INCLUDEPICTURE &quot;\(url("includepicture-simple"))&quot; \\d \"><w:r><w:t>pic</w:t></w:r></w:fldSimple>"),
            Vector(name: "includepicture-field", body: field("includepicture-field", "INCLUDEPICTURE")),
            Vector(name: "includetext-field", body: field("includetext-field", "INCLUDETEXT")),
            Vector(name: "hyperlink-field", body: field("hyperlink-field", "HYPERLINK")),
            Vector(name: "vml-href", body: "<w:r><w:pict><v:shape><v:imagedata o:href=\"\(url("vml-href"))\"/></v:shape></w:pict></w:r>"),
            Vector(name: "vml-relationship", body: "<w:r><w:pict><v:shape><v:imagedata r:id=\"rId10\"/></v:shape></w:pict></w:r>",
                   relationships: external("image", "vml-relationship")),
            Vector(name: "subdocument", body: "<w:subDoc r:id=\"rId10\"/>", relationships: external("subDocument", "subdocument")),
            Vector(name: "altchunk", body: "<w:altChunk r:id=\"rId10\"/>", relationships: external("aFChunk", "altchunk")),
            Vector(name: "attached-template", relationships: external("attachedTemplate", "attached-template"),
                   part: "<w:settings \(Self.wordNamespaces)><w:attachedTemplate r:id=\"rId10\"/></w:settings>"),
            Vector(name: "xlink-href", body: "<w:r xlink:href=\"\(url("xlink-href"))\"><w:t>x</w:t></w:r>"),
        ]
    }

    private func relationshipsXML(_ relationships: [(id: String, type: String, target: String)]) -> String {
        let items = relationships.map { "<Relationship Id=\"\($0.id)\" Type=\"\($0.type)\" Target=\"\($0.target)\" TargetMode=\"External\"/>" }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + items.joined() + "</Relationships>"
    }

    private func docx(_ vector: Vector) -> Data {
        let types = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/></Types>"
        let root = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(Self.relationshipType)officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document \(Self.wordNamespaces)><w:body>"
            + "<w:p><w:r><w:t>\(Self.visible)</w:t></w:r></w:p><w:p>\(vector.body)</w:p></w:body></w:document>"
        var entries: [(name: String, content: String)] = [
            ("[Content_Types].xml", types), ("_rels/.rels", root), ("word/document.xml", document),
            ("word/_rels/document.xml.rels", relationshipsXML(vector.part.isEmpty ? vector.relationships : [])),
        ]
        if !vector.part.isEmpty {
            entries.append(("word/settings.xml", vector.part))
            entries.append(("word/_rels/settings.xml.rels", relationshipsXML(vector.relationships)))
        }
        return ZipFixture.archive(entries)
    }

    func testReadingALocalDocxNeverConnectsAnywhere() async throws {
        try await assertNeverConnects { origin in
            try docxVectors(origin).map { (name: $0.name + ".docx", url: try write(docx($0), as: $0.name + ".docx")) }
        }
    }

    // MARK: .odt

    private static let odfNamespaces = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
    xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
    xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" \
    xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
    """

    private func odtVectors(_ origin: String) -> [Vector] {
        func link(_ name: String) -> String { "xlink:type=\"simple\" xlink:href=\"\(origin)/odt-\(name)\"" }
        return [
            Vector(name: "image", body: "<text:p><draw:frame draw:name=\"f\" svg:width=\"1cm\" svg:height=\"1cm\"><draw:image \(link("image")) xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame></text:p>"),
            Vector(name: "hyperlink", body: "<text:p><text:a \(link("hyperlink"))>a link</text:a></text:p>"),
            Vector(name: "section-source", body: "<text:section text:name=\"S\"><text:section-source \(link("section-source"))/><text:p>in section</text:p></text:section>"),
            Vector(name: "object", body: "<text:p><draw:frame draw:name=\"o\"><draw:object \(link("object"))/></draw:frame></text:p>"),
            Vector(name: "plugin", body: "<text:p><draw:frame draw:name=\"p\"><draw:plugin \(link("plugin")) draw:mime-type=\"video/mp4\"/></draw:frame></text:p>"),
            Vector(name: "script", head: "<office:scripts><office:script \(link("script"))/></office:scripts>"),
            Vector(name: "style-background",
                   part: "<office:document-styles \(Self.odfNamespaces)><office:automatic-styles><style:page-layout style:name=\"pm1\">"
                   + "<style:page-layout-properties><style:background-image \(link("style-background"))/></style:page-layout-properties>"
                   + "</style:page-layout></office:automatic-styles></office:document-styles>"),
            Vector(name: "meta-template",
                   part: "<office:document-meta \(Self.odfNamespaces)><office:meta><meta:template \(link("meta-template"))/></office:meta></office:document-meta>"),
        ]
    }

    private func odt(_ vector: Vector) -> Data {
        let manifest = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\">"
            + "<manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/></manifest:manifest>"
        let isStyles = vector.part.contains("document-styles")
        let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content \(Self.odfNamespaces)>\(vector.head)<office:body><office:text>"
            + "<text:p>\(Self.visible)</text:p>\(vector.body)</office:text></office:body></office:document-content>"
        return ZipFixture.archive([
            ("mimetype", "application/vnd.oasis.opendocument.text"), ("META-INF/manifest.xml", manifest), ("content.xml", content),
            ("styles.xml", isStyles ? vector.part : "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-styles \(Self.odfNamespaces)/>"),
            ("meta.xml", vector.part.contains("document-meta") ? vector.part
                : "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-meta \(Self.odfNamespaces)/>"),
        ])
    }

    func testReadingALocalOdtNeverConnectsAnywhere() async throws {
        try await assertNeverConnects { origin in
            try odtVectors(origin).map { (name: $0.name + ".odt", url: try write(odt($0), as: $0.name + ".odt")) }
        }
    }

    // MARK: .rtf and .rtfd

    /// RTF reaches outside the file through fields: a link, a picture or text to
    /// include, an object to link or import, and the template the document names.
    private func rtfVectors(_ origin: String) -> [(name: String, body: String)] {
        func field(_ name: String, _ instruction: String) -> String {
            "{\\field{\\*\\fldinst{\(instruction) \"\(origin)/rtf-\(name)\"}}{\\fldrslt result}}"
        }
        return [
            ("hyperlink", field("hyperlink", "HYPERLINK")),
            ("includepicture", field("includepicture", "INCLUDEPICTURE")),
            ("includepicture-switch", field("includepicture-switch", "INCLUDEPICTURE \\\\d \\\\c")),
            ("includetext", field("includetext", "INCLUDETEXT")),
            ("link", field("link", "LINK Word.Document.8")),
            ("import", field("import", "IMPORT")),
            ("template", "{\\*\\template \(origin)/rtf-template}"),
            ("linked-object", "{\\object\\objlink{\\*\\objclass Word.Document.8}{\\*\\objsource \(origin)/rtf-linked-object}}"),
        ]
    }

    private func rtf(_ body: String) -> Data {
        Data("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\(body)\\f0 \(Self.visible)\\par\n}".utf8)
    }

    func testReadingALocalRtfNeverConnectsAnywhere() async throws {
        try await assertNeverConnects { origin in
            try rtfVectors(origin).map { (name: $0.name + ".rtf", url: try write(rtf($0.body), as: $0.name + ".rtf")) }
        }
    }

    func testReadingALocalRtfdPackageNeverConnectsAnywhere() async throws {
        var packages: [URL] = []
        defer {
            for package in packages {
                try? FileManager.default.removeItem(at: package.appendingPathComponent("TXT.rtf"))
                try? FileManager.default.removeItem(at: package)
            }
        }
        try await assertNeverConnects { origin in
            try rtfVectors(origin).map { vector in
                let package = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ox-say-net-\(UUID().uuidString)-\(vector.name).rtfd")
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
                packages.append(package)
                try rtf(vector.body).write(to: package.appendingPathComponent("TXT.rtf"))
                return (name: vector.name + ".rtfd", url: package)
            }
        }
    }
}
