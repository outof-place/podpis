import AppKit
import PDFKit
import PodpisCore
import SwiftUI

/// The selected file: the page with the signature preview, or the signed result.
struct DocumentPane: View {
    @Environment(AppModel.self) private var model
    @State private var navigator = PDFNavigator()
    @State private var currentPage = 0
    private let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        if let doc = model.selected {
            content(doc)
                .id(doc.id)
                .overlay(alignment: .top) {
                    TopBanner(doc: doc)
                        .onPaper(doc.kind == .pdf && doc.loadProblem == nil)
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                }
        }
    }

    @ViewBuilder
    private func content(_ doc: Document) -> some View {
        if let problem = doc.loadProblem {
            ContentUnavailableView {
                Label("Nie mogę podpisać tego pliku", systemImage: "doc.badge.ellipsis")
            } description: {
                Text(problem)
            } actions: {
                Button("Usuń z listy") { model.remove(doc) }
            }
        } else if doc.kind == .xml {
            XMLPreview(doc: doc)
        } else if let pdf = doc.signedPDF ?? doc.pdf {
            pdfView(doc, pdf)
        } else {
            ProgressView()
        }
    }

    private func pdfView(_ doc: Document, _ pdf: PDFDocument) -> some View {
        let signed = doc.signedPDF != nil
        let spot = doc.placement.spot
        let key = spot.map { ArtRenderer.Key(name: model.holder, width: Int($0.rect.width), height: Int($0.rect.height)) }
        let skipped = doc.isSkipped(holder: model.holder)
        let stamp: StampSpec? = signed || skipped ? nil : spot.map {
            let attention: Bool
            if case .needsAttention = doc.placement { attention = true } else { attention = false }
            return StampSpec(page: $0.page, rect: $0.rect, art: key.flatMap(model.art.image(for:)),
                             attention: attention, editable: !model.phase.isBusy)
        }
        return PDFCanvas(
            document: pdf, stamp: stamp,
            revealToken: RevealToken(doc: doc.id, signed: signed, source: revealSource(doc.placement)),
            revealTarget: spot.map { ($0.page, $0.rect) },
            navigator: navigator,
            onPageChange: { currentPage = $0 },
            onStampMoved: { page, rect in model.moveStamp(doc, page: page, rect: rect) })
        .overlay {
            if doc.outcome == .signing {
                SigningOverlay(name: doc.name).onPaper()
            }
        }
        .overlay(alignment: .bottom) {
            PageBar(navigator: navigator, page: currentPage, count: pdf.pageCount,
                    stampPage: signed ? nil : spot?.page,
                    revealStamp: { if let s = spot { navigator.reveal(page: s.page, rect: s.rect) } })
                .onPaper()
                .padding(.bottom, 14)
        }
        .task(id: key) {
            if let key { model.art.ensure(key) }
        }
        .onReceive(minute) { _ in
            if let key, NSApp.isActive { model.art.ensure(key) }
        }
    }

    /// Scroll to the signature when the file changes, when it gets signed and when a new
    /// suggestion arrives, but not while the user drags it around.
    private func revealSource(_ p: Placement) -> String {
        switch p {
        case .locating: return "szukam"
        case .suggested(let page, let rect, let anchor): return "auto-\(page)-\(Int(rect.minY))-\(anchor)"
        case .needsAttention(let page, _, let reason): return "uwaga-\(page)-\(reason)"
        case .manual: return "reczne"
        }
    }

    private struct RevealToken: Hashable {
        let doc: UUID
        let signed: Bool
        let source: String
    }
}

/// Floating page controls under the page.
struct PageBar: View {
    let navigator: PDFNavigator
    let page: Int
    let count: Int
    let stampPage: Int?
    let revealStamp: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { navigator.previous() } label: { Image(systemName: "chevron.up") }
                .disabled(page <= 0)
                .help("Poprzednia strona")
            Text("Strona \(page + 1) z \(count)")
                .monospacedDigit()
                .font(.callout.weight(.medium))
                .frame(minWidth: 96)
            Button { navigator.next() } label: { Image(systemName: "chevron.down") }
                .disabled(page >= count - 1)
                .help("Następna strona")
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button { navigator.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Pomniejsz")
            Button { navigator.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Dopasuj do okna")
            Button { navigator.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Powiększ")
            if let stampPage, stampPage != page {
                Divider().frame(height: 18).padding(.horizontal, 4)
                Button(action: revealStamp) {
                    Label("Podpis na stronie \(stampPage + 1)", systemImage: "signature")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

struct SigningOverlay: View {
    let name: String

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.08))
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Podpisuję \(name)…")
                    .font(.headline)
                Text("Karta liczy podpis, to zajmuje kilka sekund.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .transition(.opacity)
    }
}

/// What the user should know about the visible file, over the page.
struct TopBanner: View {
    @Environment(AppModel.self) private var model
    let doc: Document

    var body: some View {
        Group {
            switch doc.outcome {
            case .signed(let file, let verification):
                SignedBanner(file: file, verification: verification)
            case .failed(let error):
                FailureBanner(advice: error.advice, retry: model.canSign ? { model.requestSign() } : nil)
            case .pending:
                if doc.isSkipped(holder: model.holder) {
                    hint(symbol: "signature", title: "Ten plik już podpisałeś, więc go pominę.",
                         detail: "Zaznacz „Dołóż kolejny podpis” po prawej, jeśli to zamierzone.", rotated: false)
                } else if case .needsAttention(let page, _, let reason) = doc.placement {
                    hint(symbol: "hand.draw.fill", title: reason,
                         detail: "Przeciągnij podpis albo kliknij dwukrotnie tam, gdzie ma być.",
                         rotated: isRotated(page))
                } else if let page = doc.placement.spot?.page, isRotated(page) {
                    hint(symbol: "rotate.right", title: "Ta strona jest obrócona w PDF.",
                         detail: "Podpis obróci się razem ze stroną, tak jak widzisz.", rotated: false)
                }
            case .signing:
                EmptyView()
            }
        }
        .frame(maxWidth: 640)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.smooth, value: doc.outcome)
    }

    private func isRotated(_ page: Int) -> Bool {
        doc.geometry(page: page)?.isRotated == true
    }

    private func hint(symbol: String, title: String, detail: String, rotated: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if rotated {
                    Text("Strona jest obrócona w PDF, więc podpis obróci się razem z nią.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SignedBanner: View {
    let file: SignedFile
    let verification: Verification

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: file.path)
            VStack(alignment: .leading, spacing: 2) {
                Text("Podpisano: \(file.url.lastPathComponent)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                VerificationLabel(verification: verification)
            }
            Spacer(minLength: 8)
            Button("Otwórz") { NSWorkspace.shared.open(file.url) }
            Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.green.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct VerificationLabel: View {
    let verification: Verification

    var body: some View {
        switch verification {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sprawdzam podpis…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .passed(let text):
            Label(text, systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

struct FailureBanner: View {
    let advice: Advice
    var retry: (() -> Void)?
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: advice.symbol).foregroundStyle(advice.tone == .failure ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(advice.title).font(.callout.weight(.semibold))
                    Text(advice.message).font(.callout).foregroundStyle(.secondary)
                    if let next = advice.nextStep {
                        Text(next).font(.callout)
                    }
                }
                Spacer(minLength: 8)
                if let retry {
                    Button("Spróbuj ponownie", action: retry)
                }
            }
            if let detail = advice.detail, !detail.isEmpty {
                DisclosureGroup("Szczegóły", isExpanded: $showDetail) {
                    HStack(alignment: .top) {
                        Text(detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Kopiuj") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(detail, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.red.opacity(0.1)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// XML has no stamp on a page: show what is inside so the user knows what is signed.
struct XMLPreview: View {
    let doc: Document

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 44, height: 44)
                        .background(Color.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.name).font(.title3.weight(.semibold))
                        Text("Podpis XAdES otaczany: trafi do środka pliku, bez grafiki.")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: preview)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 28)
            .padding(.top, doc.outcome.signedFile == nil ? 24 : 90)
            .padding(.bottom, 28)
        }
    }

    private var preview: String {
        let text = doc.xmlText ?? ""
        let limit = 60_000
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}
