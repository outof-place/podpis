import AppKit
import PDFKit
import QuartzCore
import SwiftUI

/// The signature preview over the page: the exact art from `podpisz grafika` in a layer
/// that sits on the PDF view's document view. It is placed from the page-space rect on
/// every scroll, zoom and drag, rotated with the page, so it matches the signed result and
/// stays sharp at any zoom (a PDFAnnotation would be rasterised by PDFKit at low resolution).
final class StampOverlayView: NSView {
    private let artLayer = CALayer()
    private let frameLayer = CAShapeLayer()
    private let placeholder = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        artLayer.contentsGravity = .resize
        artLayer.minificationFilter = .trilinear
        frameLayer.lineWidth = 1
        frameLayer.lineDashPattern = [4, 3]
        frameLayer.zPosition = -1
        placeholder.string = "Podpis…"
        placeholder.alignmentMode = .center
        placeholder.foregroundColor = NSColor(srgbRed: 0.15, green: 0.19, blue: 0.49, alpha: 0.5).cgColor
        artLayer.addSublayer(frameLayer)
        artLayer.addSublayer(placeholder)
        layer?.addSublayer(artLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `size` is the unrotated box in view points, `rotation` the page's clockwise rotation.
    func show(size: CGSize, rotation: Int, art: NSImage?, attention: Bool, editable: Bool, dragging: Bool, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artLayer.bounds = CGRect(origin: .zero, size: size)
        artLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        artLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180))
        artLayer.contents = art
        artLayer.contentsScale = window?.backingScaleFactor ?? 2

        let tint = attention ? NSColor.systemOrange : NSColor.controlAccentColor
        let pad = max(3, 3 * scale)
        let corner = 4 * max(1, scale)
        frameLayer.isHidden = !editable
        frameLayer.path = CGPath(roundedRect: artLayer.bounds.insetBy(dx: -pad, dy: -pad),
                                 cornerWidth: corner, cornerHeight: corner, transform: nil)
        frameLayer.strokeColor = tint.withAlphaComponent(dragging ? 0.95 : 0.65).cgColor
        frameLayer.fillColor = tint.withAlphaComponent(dragging ? 0.14 : 0.06).cgColor

        placeholder.isHidden = art != nil
        placeholder.fontSize = max(8, size.height * 0.3)
        placeholder.contentsScale = artLayer.contentsScale
        placeholder.frame = CGRect(x: 0, y: (size.height - placeholder.fontSize * 1.25) / 2,
                                   width: size.width, height: placeholder.fontSize * 1.25)
        CATransaction.commit()
    }
}

/// PDFView that lets the user drag the signature, or double-click to drop it somewhere else.
final class SignaturePDFView: PDFView {
    private(set) var stampPage: PDFPage?
    private(set) var stampRect: CGRect = .zero
    private var art: NSImage?
    private var attention = false
    private var editable = true
    private var dragOffset: CGSize?
    private let overlay = StampOverlayView(frame: .zero)
    private var observers: [NSObjectProtocol] = []
    var onStampMoved: ((PDFPage, CGRect) -> Void)?

    func setStamp(page: PDFPage?, rect: CGRect, art: NSImage?, attention: Bool, editable: Bool) {
        guard dragOffset == nil else { return }  // the drag owns the position until mouse up
        stampPage = page
        stampRect = rect
        self.art = art
        self.attention = attention
        self.editable = editable
        layoutStamp()
    }

    /// Puts the overlay on the current document view and follows its scrolling and zoom.
    func attachOverlay() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let docView = documentView else { return }
        if overlay.superview !== docView {
            overlay.removeFromSuperview()
            docView.addSubview(overlay)
        }
        let center = NotificationCenter.default
        let relayout: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutStamp() }
        }
        if let clip = docView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: relayout))
        }
        docView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: docView, queue: .main, using: relayout))
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: self, queue: .main, using: relayout))
        layoutStamp()
    }

    override func layout() {
        super.layout()
        layoutStamp()
    }

    func layoutStamp() {
        guard let page = stampPage, let docView = documentView, page.document === document else {
            overlay.isHidden = true
            return
        }
        overlay.isHidden = false
        if overlay.superview !== docView { docView.addSubview(overlay) }
        // The document view may be magnified by its clip view, so measure the box in its own
        // units instead of trusting scaleFactor.
        let inDoc = docView.convert(convert(stampRect, from: page), from: self)
        let quarter = page.rotation % 180 != 0
        let size = quarter ? CGSize(width: inDoc.height, height: inDoc.width) : inDoc.size
        let s = stampRect.width > 0 ? size.width / stampRect.width : 1
        let pad = 6 * max(1, s)
        overlay.frame = inDoc.insetBy(dx: -pad, dy: -pad)
        overlay.show(size: size, rotation: page.rotation, art: art, attention: attention, editable: editable,
                     dragging: dragOffset != nil, scale: s)
    }

    private func pagePoint(_ event: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: true) else { return nil }
        return (page, convert(p, to: page))
    }

    private func isOverStamp(_ event: NSEvent) -> Bool {
        guard editable, let page = stampPage, let h = pagePoint(event), h.page === page else { return false }
        return stampRect.insetBy(dx: -4, dy: -4).contains(h.point)
    }

    private func clamp(_ r: CGRect, page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        var b = r
        b.origin.x = min(max(b.minX, crop.minX), max(crop.minX, crop.maxX - b.width))
        b.origin.y = min(max(b.minY, crop.minY), max(crop.minY, crop.maxY - b.height))
        return b
    }

    private func move(to page: PDFPage, rect: CGRect) {
        stampPage = page
        stampRect = clamp(rect, page: page)
        layoutStamp()
    }

    override func mouseDown(with event: NSEvent) {
        guard editable, stampPage != nil, let h = pagePoint(event) else { return super.mouseDown(with: event) }
        if isOverStamp(event) {
            dragOffset = CGSize(width: h.point.x - stampRect.minX, height: h.point.y - stampRect.minY)
            layoutStamp()
            NSCursor.closedHand.set()
            return
        }
        if event.clickCount == 2 {
            let size = stampRect.size
            move(to: h.page, rect: CGRect(x: h.point.x - size.width / 2, y: h.point.y - size.height / 2,
                                          width: size.width, height: size.height))
            onStampMoved?(h.page, stampRect)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = dragOffset, let h = pagePoint(event) else { return super.mouseDragged(with: event) }
        let size = stampRect.size
        move(to: h.page, rect: CGRect(x: h.point.x - offset.width, y: h.point.y - offset.height,
                                      width: size.width, height: size.height))
        NSCursor.closedHand.set()
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else { return super.mouseUp(with: event) }
        dragOffset = nil
        layoutStamp()
        if let page = stampPage { onStampMoved?(page, stampRect) }
        NSCursor.openHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if dragOffset == nil, isOverStamp(event) { NSCursor.openHand.set() }
    }

    /// Option + arrow keys nudge the signature by a point, with Shift by 10 points.
    override func keyDown(with event: NSEvent) {
        guard editable, let page = stampPage, event.modifierFlags.contains(.option) else {
            return super.keyDown(with: event)
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var r = stampRect
        switch event.keyCode {
        case 123: r.origin.x -= step
        case 124: r.origin.x += step
        case 125: r.origin.y -= step
        case 126: r.origin.y += step
        default: return super.keyDown(with: event)
        }
        move(to: page, rect: r)
        onStampMoved?(page, stampRect)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Commands from SwiftUI buttons to the PDF view.
@MainActor
final class PDFNavigator {
    weak var view: SignaturePDFView?

    func next() { view?.goToNextPage(nil) }
    func previous() { view?.goToPreviousPage(nil) }
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fit() { view?.autoScales = true }

    func reveal(page index: Int, rect: CGRect) {
        guard let view, let page = view.document?.page(at: index) else { return }
        view.go(to: rect.insetBy(dx: -120, dy: -160), on: page)
    }
}

struct StampSpec: Equatable {
    var page: Int
    var rect: CGRect
    var art: NSImage?
    var attention: Bool
    var editable: Bool

    static func == (a: StampSpec, b: StampSpec) -> Bool {
        a.page == b.page && a.rect == b.rect && a.art === b.art && a.attention == b.attention && a.editable == b.editable
    }
}

struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    var stamp: StampSpec?
    /// Changes when the view should scroll to `revealTarget` (a new file or a new suggestion).
    var revealToken: AnyHashable
    var revealTarget: (page: Int, rect: CGRect)?
    let navigator: PDFNavigator
    var onPageChange: (Int) -> Void
    var onStampMoved: (Int, CGRect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SignaturePDFView {
        let view = SignaturePDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.displayBox = .cropBox
        view.autoScales = true
        view.backgroundColor = .clear
        view.pageShadowsEnabled = true
        view.interpolationQuality = .high
        navigator.view = view
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: SignaturePDFView, context: Context) {
        let c = context.coordinator
        c.onPageChange = onPageChange
        view.onStampMoved = { page, rect in
            guard let doc = view.document else { return }
            onStampMoved(doc.index(for: page), rect)
        }
        navigator.view = view

        if view.document !== document {
            view.document = document
            view.autoScales = true
            view.attachOverlay()
            c.revealed = nil
            DispatchQueue.main.async { onPageChange(view.currentPage.map { document.index(for: $0) } ?? 0) }
        }

        if let spec = stamp, let page = document.page(at: spec.page) {
            view.setStamp(page: page, rect: spec.rect, art: spec.art, attention: spec.attention, editable: spec.editable)
        } else {
            view.setStamp(page: nil, rect: .zero, art: nil, attention: false, editable: false)
        }

        if c.revealed != revealToken {
            c.revealed = revealToken
            if let t = revealTarget {
                // after PDFKit has laid out the new document
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { navigator.reveal(page: t.page, rect: t.rect) }
            }
        }
    }

    @MainActor
    final class Coordinator {
        var revealed: AnyHashable?
        var onPageChange: ((Int) -> Void)?
        private var observer: NSObjectProtocol?

        func observe(_ view: SignaturePDFView) {
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, let page = view.currentPage, let doc = view.document else { return }
                    self?.onPageChange?(doc.index(for: page))
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
