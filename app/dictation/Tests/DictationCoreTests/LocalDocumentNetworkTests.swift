import Foundation
import XCTest
@testable import DictationCore

/// A local HTML file or web archive must never make this Mac touch the network.
/// The oracle is a real listener on 127.0.0.1: each page below points at it
/// through one way a page can load something, and after reading all of them
/// (plus a short wait for a late request) the listener must have seen nobody.
final class LocalDocumentNetworkTests: XCTestCase {
    /// Time given to a request that was started but not yet sent.
    private static let graceNanoseconds: UInt64 = 600_000_000
    private static let visible = "Visible text."

    private struct Vector {
        var name: String
        var head = ""
        var bodyAttributes = ""
        var body = ""
    }

    /// Every way a page can load something that the review found, and the others
    /// a browser engine knows. `origin` is the listener.
    private func vectors(_ origin: String) -> [Vector] {
        func url(_ name: String) -> String { "\(origin)/\(name)" }
        return [
            Vector(name: "img", body: "<img src=\"\(url("img"))\">"),
            Vector(name: "img-lowsrc", body: "<img src=\"data:,\" lowsrc=\"\(url("img-lowsrc"))\">"),
            Vector(name: "link", head: "<link rel=\"stylesheet\" href=\"\(url("link"))\">"),
            Vector(name: "link-icon", head: "<link rel=\"icon\" href=\"\(url("link-icon"))\">"),
            Vector(name: "body-background", bodyAttributes: "background=\"\(url("body-background"))\""),
            Vector(name: "td-background", body: "<table><tr><td background=\"\(url("td-background"))\">cell</td></tr></table>"),
            Vector(name: "table-background", body: "<table background=\"\(url("table-background"))\"><tr><td>cell</td></tr></table>"),
            Vector(name: "input-image", body: "<input type=\"image\" src=\"\(url("input-image"))\">"),
            Vector(name: "inline-style", body: "<div style=\"background:url(\(url("inline-style")))\">styled</div>"),
            Vector(name: "list-style-image", body: "<ul style=\"list-style-image:url(\(url("list-style-image")))\"><li>item</li></ul>"),
            Vector(name: "srcset", body: "<img srcset=\"\(url("srcset")) 2x\" src=\"data:,\">"),
            Vector(name: "picture-source", body: "<picture><source srcset=\"\(url("picture-source"))\"><img src=\"data:,\"></picture>"),
            Vector(name: "style-block", head: "<style>body { background: url(\(url("style-block"))) }</style>"),
            Vector(name: "import", head: "<style>@import url(\"\(url("import"))\");</style>"),
            Vector(name: "import-link", head: "<style>@import \"\(url("import-link"))\";</style>"),
            Vector(name: "object", body: "<object data=\"\(url("object"))\">fallback</object>"),
            Vector(name: "embed", body: "<embed src=\"\(url("embed"))\">"),
            Vector(name: "iframe", body: "<iframe src=\"\(url("iframe"))\"></iframe>"),
            Vector(name: "frame", body: "<frameset><frame src=\"\(url("frame"))\"></frameset>"),
            Vector(name: "meta-refresh", head: "<meta http-equiv=\"refresh\" content=\"0;url=\(url("meta-refresh"))\">"),
            Vector(name: "base", head: "<base href=\"\(origin)/base/\">", body: "<img src=\"relative.png\"><link rel=\"stylesheet\" href=\"relative.css\">"),
            Vector(name: "script-src", body: "<script src=\"\(url("script-src"))\"></script>"),
            Vector(name: "script-unclosed", body: "<script src=\"\(url("script-unclosed"))\">"),
            Vector(name: "applet", body: "<applet code=\"X\" archive=\"\(url("applet"))\">fallback</applet>"),
            Vector(name: "video", body: "<video poster=\"\(url("video-poster"))\" src=\"\(url("video"))\"></video>"),
            Vector(name: "audio", body: "<audio src=\"\(url("audio"))\"></audio>"),
            Vector(name: "svg-image", body: "<svg><image href=\"\(url("svg-image"))\"/></svg>"),
            Vector(name: "anchor", body: "<a href=\"\(url("anchor"))\">a link</a>"),
            Vector(name: "form", body: "<form action=\"\(url("form"))\"><input name=\"q\"></form>"),
        ]
    }

    private func page(_ vector: Vector, doctype: String = "") -> String {
        "\(doctype)<html><head>\(vector.head)</head><body \(vector.bodyAttributes)>\(Self.visible)\(vector.body)</body></html>"
    }

    /// The pages, each also as the main resource of a web archive.
    private func files(_ origin: String) throws -> [(name: String, url: URL)] {
        var pages = vectors(origin).map { (name: $0.name, html: page($0)) }
        let doctype = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"\(origin)/doctype.dtd\">"
        pages.append((name: "doctype", html: page(Vector(name: "doctype"), doctype: doctype)))
        pages.append((name: "xml-stylesheet",
                      html: "<?xml-stylesheet type=\"text/css\" href=\"\(origin)/xml-stylesheet\"?>" + page(Vector(name: "xml-stylesheet"))))
        pages.append((name: "xml-entity",
                      html: "<!DOCTYPE html [<!ENTITY ext SYSTEM \"\(origin)/xml-entity\">]>" + page(Vector(name: "xml-entity", body: "&ext;"))))
        var made: [(name: String, url: URL)] = []
        for (name, html) in pages {
            made.append((name + ".html", try write(Data(html.utf8), as: "\(name).html")))
            let plist: [String: Any] = ["WebMainResource": ["WebResourceData": Data(html.utf8), "WebResourceMIMEType": "text/html",
                                                           "WebResourceURL": "\(origin)/main"]]
            let archive = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            made.append((name + ".webarchive", try write(archive, as: "\(name).webarchive")))
        }
        return made
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ox-say-net-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
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

    func testReadingALocalHtmlFileOrWebArchiveNeverConnectsAnywhere() async throws {
        let listener = try LoopbackListener()
        defer { listener.stop() }
        let documents = try files(listener.origin)
        defer { documents.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        var lost: [String] = []
        for (name, url) in documents {
            let document = try await DocumentReader.read(url)
            if !document.script.contains(Self.visible) { lost.append(name) }
        }
        try await Task.sleep(nanoseconds: Self.graceNanoseconds)
        XCTAssertEqual(listener.connections, [], "a local file made the Mac open connections")
        XCTAssertEqual(lost, [], "the visible text must survive every page")
        XCTAssertEqual(documents.count, 2 * (vectors(listener.origin).count + 3))
    }
}
