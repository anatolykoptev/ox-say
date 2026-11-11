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

    @MainActor
    func testUnknownSymbolIsNil() {
        XCTAssertNil(StatusIconImage.make(symbol: "no.such.symbol.zz", red: true, description: ""))
    }
}
