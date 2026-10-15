import AppKit
import PDFKit
@testable import Podpis
import Testing

/// Dragging the signature must move it exactly with the pointer on screen, on plain and on
/// rotated pages (with an offset media box), and keep it on the page. Expected positions
/// come from PDFKit's own view-to-page conversion, not from the app's code.
@MainActor @Suite struct StampDragTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    struct Rig {
        let window: NSWindow
        let view: SignaturePDFView
        let page: PDFPage
        var moved: (PDFPage, CGRect)?
    }

    func rig(_ fixture: String, rect: CGRect) throws -> (NSWindow, SignaturePDFView, PDFPage, Box) {
        let doc = try #require(PDFDocument(url: Self.fixtures.appendingPathComponent(fixture)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = SignaturePDFView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.displayMode = .singlePage
        view.autoScales = true
        view.document = doc
        view.attachOverlay()
        window.layoutIfNeeded()
        let page = try #require(doc.page(at: 0))
        view.setStamp(page: page, rect: rect, art: nil, attention: false, editable: true)
        let box = Box()
        view.onStampMoved = { p, r in box.value = (p, r) }
        return (window, view, page, box)
    }

    final class Box { var value: (PDFPage, CGRect)? }

    func event(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Centre of the stamp in window coordinates, through PDFKit.
    func centre(_ rect: CGRect, _ view: SignaturePDFView, _ page: PDFPage) -> NSPoint {
        let r = view.convert(view.convert(rect, from: page), to: nil)
        return NSPoint(x: r.midX, y: r.midY)
    }

    @Test(arguments: ["uchwala-zarzadu.pdf", "uchwala-obrot-90.pdf", "uchwala-obrot-180.pdf", "uchwala-obrot-270.pdf"])
    func stampFollowsThePointer(fixture: String) throws {
        let start = CGRect(x: 250, y: 300, width: 190, height: 48)
        let (window, view, page, box) = try rig(fixture, rect: start)
        let from = centre(start, view, page)
        let to = NSPoint(x: from.x + 60, y: from.y - 40)
        view.mouseDown(with: event(.leftMouseDown, at: from, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: from.x + 30, y: from.y - 20), in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: to, in: window))
        view.mouseUp(with: event(.leftMouseUp, at: to, in: window))
        let (movedPage, rect) = try #require(box.value)
        #expect(movedPage === page)
        #expect(rect.size == start.size)
        let now = centre(rect, view, page)
        #expect(abs(now.x - to.x) < 1.5 && abs(now.y - to.y) < 1.5, "\(fixture): centre \(now) expected \(to)")
    }

    @Test func doubleClickDropsTheStampThere() throws {
        let start = CGRect(x: 250, y: 300, width: 190, height: 48)
        let (window, view, page, box) = try rig("uchwala-zarzadu.pdf", rect: start)
        let target = centre(CGRect(x: 100, y: 600, width: 10, height: 10), view, page)
        view.mouseDown(with: event(.leftMouseDown, at: target, in: window, clicks: 2))
        let (_, rect) = try #require(box.value)
        let now = centre(rect, view, page)
        #expect(abs(now.x - target.x) < 1.5 && abs(now.y - target.y) < 1.5)
    }

    @Test func stampStaysOnThePage() throws {
        let start = CGRect(x: 250, y: 300, width: 190, height: 48)
        let (window, view, page, box) = try rig("uchwala-zarzadu.pdf", rect: start)
        let from = centre(start, view, page)
        let far = NSPoint(x: from.x + 3000, y: from.y - 3000)
        view.mouseDown(with: event(.leftMouseDown, at: from, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: far, in: window))
        view.mouseUp(with: event(.leftMouseUp, at: far, in: window))
        let (_, rect) = try #require(box.value)
        let crop = page.bounds(for: .cropBox)
        #expect(crop.contains(rect), "\(rect) outside \(crop)")
    }
}
