import AppKit
import Observation
import PDFKit
import PodpisCore

/// Where the signature goes on a PDF. Pages are 0-based here, rects in PDF user space.
enum Placement: Equatable {
    case locating
    /// Found by `podpisz miejsce` above the anchor text.
    case suggested(page: Int, rect: CGRect, anchor: String)
    /// Moved by the user.
    case manual(page: Int, rect: CGRect)
    /// A default spot because the anchor was missing or had no room: the user should look.
    case needsAttention(page: Int, rect: CGRect, reason: String)

    var spot: (page: Int, rect: CGRect)? {
        switch self {
        case .locating: return nil
        case .suggested(let p, let r, _), .manual(let p, let r), .needsAttention(let p, let r, _): return (p, r)
        }
    }

    var isLocating: Bool { self == .locating }
}

enum ExistingSignatures: Equatable {
    case checking
    case none
    case signed(by: [String])

    var signers: [String]? {
        if case .signed(let s) = self { return s }
        return nil
    }
}

enum Verification: Equatable {
    case checking
    case passed(String)
    case failed(String)
}

enum Outcome: Equatable {
    case pending
    case signing
    case signed(SignedFile, Verification)
    case failed(PodpisError)

    var signedFile: SignedFile? {
        if case .signed(let f, _) = self { return f }
        return nil
    }
}

/// One dropped file and everything decided about it.
@MainActor @Observable
final class Document: Identifiable {
    let id = UUID()
    let url: URL
    let kind: DocumentKind
    var pdf: PDFDocument?
    var xmlText: String?
    var loadProblem: String?
    var existing: ExistingSignatures = .checking
    /// Sign again even though the card holder already signed this file.
    var addAnother = false
    var anchor: String
    /// PDF only; an XML signature has no visible stamp.
    var placement: Placement = .locating
    var output: OutputNaming.Plan
    var outcome: Outcome = .pending
    /// The signed copy, loaded for the preview once it exists.
    var signedPDF: PDFDocument?
    @ObservationIgnored var locateTask: Task<Void, Never>?

    init(url: URL, kind: DocumentKind, anchor: String, output: OutputNaming.Plan) {
        self.url = url
        self.kind = kind
        self.anchor = anchor
        self.output = output
    }

    var name: String { url.lastPathComponent }
    var pageCount: Int { pdf?.pageCount ?? 0 }

    func signedByHolder(_ holder: String) -> Bool {
        guard let s = existing.signers else { return false }
        return DocumentInspector.signedBy(holder, in: s)
    }

    /// Already signed by the card holder and not asked to sign again: left out of the batch.
    func isSkipped(holder: String) -> Bool {
        signedByHolder(holder) && !addAnother
    }

    /// Whether this file goes into the next batch.
    func isReadyToSign(holder: String) -> Bool {
        guard loadProblem == nil, existing != .checking else { return false }
        switch outcome {
        case .pending, .failed: break
        case .signing, .signed: return false
        }
        if isSkipped(holder: holder) { return false }
        if kind == .pdf { return placement.spot != nil }
        return true
    }

    func geometry(page index: Int) -> PageGeometry? {
        guard let page = pdf?.page(at: index) else { return nil }
        return PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
    }

    func cropBox(page index: Int) -> CGRect? {
        pdf?.page(at: index)?.bounds(for: .cropBox)
    }
}
