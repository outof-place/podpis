import CoreGraphics
import Foundation
import PDFKit
@testable import PodpisCore
import Testing

/// `podpisz miejsce` measures the page the way poppler sees it; the app draws and signs in
/// PDF user space. If the conversion is wrong on a rotated page or a media box that does not
/// start at 0,0, the preview and the signature land in the wrong place.
@Suite struct PageGeometryTests {
    @Test(arguments: [0, 90, 180, 270])
    func roundTripsEveryRotation(rotation: Int) {
        let g = PageGeometry(mediaBox: CGRect(x: 30, y: 40, width: 595, height: 842), rotation: rotation)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 700), CGPoint(x: 590, y: 12)] {
            let back = g.popplerPoint(fromUser: g.userPoint(fromPoppler: p))
            #expect(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001)
        }
    }

    @Test func unrotatedPageAtOriginIsIdentity() {
        let g = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 595, height: 842), rotation: 0)
        let r = CGRect(x: 339, y: 378, width: 190, height: 48)
        #expect(g.userRect(fromPoppler: r) == r)
        #expect(g.signatureBox(fromPoppler: r) == r)
    }

    @Test func signatureBoxKeepsItsSizeOnQuarterTurns() {
        let g = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 595, height: 842), rotation: 90)
        let box = g.signatureBox(fromPoppler: CGRect(x: 300, y: 200, width: 190, height: 48))
        #expect(box.size == CGSize(width: 190, height: 48))
    }

    @Test func clampKeepsTheBoxOnThePage() {
        let crop = CGRect(x: 0, y: 0, width: 595, height: 842)
        let out = PageGeometry.clamp(CGRect(x: 520, y: -20, width: 190, height: 48), into: crop)
        #expect(out == CGRect(x: 405, y: 0, width: 190, height: 48))
    }

    /// Poppler and PDFKit locate the same words independently. Mapping poppler's box through
    /// PageGeometry must land on PDFKit's box, for every rotation and an offset media box.
    @Test(arguments: ["uchwala-zarzadu.pdf", "uchwala-obrot-90.pdf", "uchwala-obrot-180.pdf", "uchwala-obrot-270.pdf"])
    func popplerWordsMapOntoPDFKitWords(fixture: String) throws {
        let url = Paths.fixture(fixture)
        guard let pdftotext = ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"]
            .first(where: FileManager.default.isExecutableFile) else { return }
        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        let geometry = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: pdftotext)
        p.arguments = ["-bbox", "-f", "1", "-l", "1", url.path, "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        let pageMatch = xml.firstMatch(of: #/<page width="[\d.]+" height="([\d.]+)"/#)
        let wordMatch = xml.firstMatch(of: #/xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">Kowalski</#)
        let pageHeight = try #require(pageMatch.flatMap { Double($0.1) })
        let word = try #require(wordMatch)
        let (x0, y0, x1, y1) = (Double(word.1)!, Double(word.2)!, Double(word.3)!, Double(word.4)!)
        // the CLI flips poppler's top-left y with the page height, exactly like this
        let poppler = CGRect(x: x0, y: pageHeight - y1, width: x1 - x0, height: y1 - y0)
        let mapped = geometry.userRect(fromPoppler: poppler)

        let hit = try #require(doc.findString("Kowalski", withOptions: []).first)
        let kit = hit.bounds(for: page)
        #expect(abs(mapped.midX - kit.midX) < 2, "x: poppler \(mapped) vs PDFKit \(kit)")
        #expect(abs(mapped.midY - kit.midY) < 2, "y: poppler \(mapped) vs PDFKit \(kit)")
    }
}
