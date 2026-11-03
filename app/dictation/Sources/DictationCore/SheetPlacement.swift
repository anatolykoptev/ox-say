import CoreGraphics

/// Where a sheet window lands on a capture of its parent window. A sheet is a window of its own, so
/// `screencapture -l<parent>` leaves it out; the Shots harness captures it separately and draws it at this rect.
/// Screen coordinates have the origin bottom-left (y up), which is also CGContext's: no flip is needed to draw.
public enum SheetPlacement {
    /// The sheet's rect inside the parent's image, in pixels, origin bottom-left. `scale` is pixels per point.
    public static func rect(main: CGRect, sheet: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (sheet.minX - main.minX) * scale, y: (sheet.minY - main.minY) * scale,
               width: sheet.width * scale, height: sheet.height * scale)
    }

    /// The same rect's top edge measured from the top of an image `imageHeight` tall (for views that count from the top).
    public static func topLeftY(of rect: CGRect, imageHeight: CGFloat) -> CGFloat { imageHeight - rect.maxY }
}
