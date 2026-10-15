import CoreGraphics

/// Converts between the two coordinate systems a page has in this app.
///
/// * User space: raw PDF coordinates of the page, unrotated. PDFKit page space, PDF
///   annotation rects and `podpisz pdf --rect` all use it.
/// * Poppler space: what `podpisz miejsce` returns. Poppler measures the media box as
///   displayed (after /Rotate) from its top-left corner, and the CLI turns that y upside
///   down with the page height `pdftotext -bbox` reports. Poppler reports the unrotated
///   media height there even on a quarter-turned page, so the flip has to use exactly that
///   number or a 90 or 270 page lands off by the difference between its width and height.
///
/// For an unrotated page whose media box starts at 0,0 the two are the same.
public struct PageGeometry: Equatable, Sendable {
    public let mediaBox: CGRect
    /// Clockwise display rotation, normalised to 0, 90, 180 or 270.
    public let rotation: Int

    public init(mediaBox: CGRect, rotation: Int) {
        self.mediaBox = mediaBox.standardized
        self.rotation = ((rotation % 360) + 360) % 360 / 90 * 90
    }

    public var isRotated: Bool { rotation != 0 }

    public func userPoint(fromPoppler p: CGPoint) -> CGPoint {
        let m = mediaBox
        let (dx, dy) = (p.x, m.height - p.y)   // undo the CLI's flip: displayed, from the top-left
        let (x, y): (CGFloat, CGFloat)          // unrotated, from the media box's bottom-left
        switch rotation {
        case 90: (x, y) = (dy, dx)
        case 180: (x, y) = (m.width - dx, dy)
        case 270: (x, y) = (m.width - dy, m.height - dx)
        default: (x, y) = (dx, m.height - dy)
        }
        return CGPoint(x: m.minX + x, y: m.minY + y)
    }

    public func popplerPoint(fromUser u: CGPoint) -> CGPoint {
        let m = mediaBox
        let (x, y) = (u.x - m.minX, u.y - m.minY)
        let (dx, dy): (CGFloat, CGFloat)
        switch rotation {
        case 90: (dx, dy) = (y, x)
        case 180: (dx, dy) = (m.width - x, y)
        case 270: (dx, dy) = (m.height - y, m.width - x)
        default: (dx, dy) = (x, m.height - y)
        }
        return CGPoint(x: dx, y: m.height - dy)
    }

    /// The same region of the page in user space (width and height swap on 90 and 270).
    public func userRect(fromPoppler r: CGRect) -> CGRect {
        let a = userPoint(fromPoppler: CGPoint(x: r.minX, y: r.minY))
        let b = userPoint(fromPoppler: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Where the signature box goes in user space for a spot the CLI suggested.
    ///
    /// The CLI draws the art unrotated in user space, so the box keeps its width and height
    /// and only its centre moves. On a rotated page the art then shows rotated with the page,
    /// which is what the signed file will look like.
    public func signatureBox(fromPoppler r: CGRect) -> CGRect {
        let c = userPoint(fromPoppler: CGPoint(x: r.midX, y: r.midY))
        return CGRect(x: (c.x - r.width / 2).rounded(), y: (c.y - r.height / 2).rounded(),
                      width: r.width.rounded(), height: r.height.rounded())
    }

    /// Moves `box` inside `bounds` (the visible crop box) without resizing it.
    public static func clamp(_ box: CGRect, into bounds: CGRect) -> CGRect {
        var b = box
        if b.width > bounds.width { b.origin.x = bounds.midX - b.width / 2 } else {
            b.origin.x = min(max(b.minX, bounds.minX), bounds.maxX - b.width)
        }
        if b.height > bounds.height { b.origin.y = bounds.midY - b.height / 2 } else {
            b.origin.y = min(max(b.minY, bounds.minY), bounds.maxY - b.height)
        }
        return b
    }
}
