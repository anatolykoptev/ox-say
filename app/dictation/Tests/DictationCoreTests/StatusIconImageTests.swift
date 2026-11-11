import AppKit
import XCTest
@testable import DictationCore

/// #519: `contentTintColor` is ignored for a template image in the menu bar, which draws it in the bar's own black or
/// white. The recording icon is a non-template image with the red painted in.
final class StatusIconImageTests: XCTestCase {
    @MainActor
    private func average(_ image: NSImage) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        let w = 44, h = 44
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var n: CGFloat = 0
        for x in 0..<w { for y in 0..<h {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; a += c.alphaComponent; n += 1
        } }
        return n > 0 ? (r / n, g / n, b / n, a / n) : nil
    }

    /// Mutation: StatusIconImage.make, `isTemplate = false` -> `true`, or drop the palette configuration -> RED.
    @MainActor
    func testTheRecordingIconIsARedNonTemplateImage() throws {
        let image = try XCTUnwrap(StatusIconImage.make(symbol: "record.circle.fill", red: true, description: "rec"))
        XCTAssertFalse(image.isTemplate, "a template is drawn in the menu bar's own colour, tint ignored")
        let c = try XCTUnwrap(average(image), "the symbol drew nothing")
        XCTAssertGreaterThan(c.r, 0.6)
        XCTAssertLessThan(c.g, 0.45)
        XCTAssertLessThan(c.b, 0.45)
    }

    @MainActor
    func testTheIdleIconStaysATemplateSoTheBarColoursIt() throws {
        let image = try XCTUnwrap(StatusIconImage.make(symbol: "mic.fill", red: false, description: "idle"))
        XCTAssertTrue(image.isTemplate)
    }

    /// An update offered during a recording keeps its dot on the RED image (Codex review of cb38f0f): one composition
    /// for both paths. Mutation: StatusIconImage.badged, draw no dot (delete the `fill()` line) -> RED.
    @MainActor
    func testTheUpdateDotIsComposedOntoTheRedRecordingImageToo() throws {
        let red = try XCTUnwrap(StatusIconImage.make(symbol: "record.circle.fill", red: true, description: "rec"))
        let badged = StatusIconImage.badged(red, red: true, description: "update")
        XCTAssertFalse(badged.isTemplate, "a red image stays painted, not a template")
        let corner = try XCTUnwrap(cornerAverage(badged), "the corner drew nothing")
        XCTAssertGreaterThan(corner.r, 0.6)
        let plain = cornerAverage(red)
        XCTAssertNil(plain, "the bare symbol leaves the top-right corner empty, so the dot is what colours it")
        let idle = StatusIconImage.badged(try XCTUnwrap(StatusIconImage.make(symbol: "mic.fill", red: false, description: "x")), red: false, description: "update")
        XCTAssertTrue(idle.isTemplate, "the idle icon with a dot is still a template")
    }

    /// Average colour of the top-right 7x7 pixels of a 44 px render.
    @MainActor
    private func cornerAverage(_ image: NSImage) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let w = 44, h = 44
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
        for x in (w - 7)..<w { for y in 0..<7 {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        } }
        return n > 5 ? (r / n, g / n, b / n) : nil
    }

    @MainActor
    func testUnknownSymbolIsNil() {
        XCTAssertNil(StatusIconImage.make(symbol: "no.such.symbol.zz", red: true, description: ""))
    }
}
