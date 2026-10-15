import AppKit
import Observation
import PDFKit
import PodpisCore

/// What the batch is doing right now.
enum BatchPhase: Equatable {
    case idle
    case authenticating
    case signing(index: Int, total: Int, name: String)
    case finished(signed: Int, failed: Int)

    var isBusy: Bool {
        switch self {
        case .authenticating, .signing: return true
        case .idle, .finished: return false
        }
    }
}

/// The PIN sheet, with what the user is about to sign.
struct PinRequest: Identifiable, Equatable {
    enum Mode: Equatable { case normal, lowTries, lastTry }
    struct Line: Equatable, Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let attention: Bool
    }

    let id = UUID()
    let mode: Mode
    let note: String?
    let lines: [Line]
    let signer: String
    let canRemember: Bool
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let client: PodpisClient
    let card: CardMonitor
    let vault: PinVault
    let art: ArtRenderer

    var documents: [Document] = []
    var selectionID: Document.ID?
    var defaultAnchor: String {
        didSet { UserDefaults.standard.set(defaultAnchor, forKey: "kotwica") }
    }
    var phase: BatchPhase = .idle
    var batchProblem: Advice?
    var pinRequest: PinRequest?
    var toast: Toast?
    var stopAfterCurrent = false

    @ObservationIgnored private let cliSlots = AsyncLimiter(2)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingOpen: [URL] = []

    private init() {
        client = PodpisClient.configured()
        vault = PinVault(realCard: client.executable == PodpisClient.defaultExecutable)
        card = CardMonitor(client: client)
        art = ArtRenderer(client: client)
        defaultAnchor = UserDefaults.standard.string(forKey: "kotwica") ?? ""
    }

    func start() {
        guard !started else { return }
        started = true
        card.onHolderChange = { [weak self] _ in self?.relocateUnanchored() }
        card.start()
        art.learnDefaults()
        let pending = pendingOpen
        pendingOpen = []
        if !pending.isEmpty { DispatchQueue.main.async { self.open(pending) } }
    }

    /// Files from the Dock or Finder can arrive before the window exists, or in the middle of
    /// a SwiftUI update; adding them on the next turn of the run loop keeps every view in sync.
    func openWhenReady(_ urls: [URL]) {
        guard started else {
            pendingOpen += urls
            return
        }
        DispatchQueue.main.async { self.open(urls) }
    }

    // MARK: derived state

    /// Running against a fake CLI (PODPIS_CLI): shown everywhere, so nobody types a real PIN.
    var isTestMode: Bool { client.executable != PodpisClient.defaultExecutable }

    var selected: Document? {
        documents.first { $0.id == selectionID } ?? documents.first
    }

    /// The text the signature goes above: the Settings value, else the name on the card, else empty.
    var anchorText: String {
        let custom = defaultAnchor.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? (card.state.info?.name ?? "") : custom
    }

    /// The name on the card, or the anchor text before the first status arrives.
    var holder: String { card.state.info?.name ?? anchorText }

    var queue: [Document] { documents.filter { $0.isReadyToSign(holder: holder) } }

    var hasPDFs: Bool { documents.contains { $0.kind == .pdf } }

    /// Why the sign button is disabled, in plain words; nil when signing can start.
    var signBlocker: String? {
        if phase.isBusy { return nil }
        if let b = card.state.blocker { return b }
        let open = documents.filter { $0.loadProblem == nil && $0.outcome.signedFile == nil }
        if open.contains(where: { $0.kind == .pdf && $0.placement.isLocating }) { return "Szukam miejsca na podpis…" }
        if open.contains(where: { $0.existing == .checking }) { return "Sprawdzam, czy pliki mają już podpisy…" }
        if queue.isEmpty { return open.isEmpty ? nil : "Nie ma nic do podpisania." }
        return nil
    }

    var canSign: Bool { !phase.isBusy && signBlocker == nil && !queue.isEmpty }

    // MARK: files

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .xml]
        panel.message = "Wybierz PDF albo XML do podpisu"
        panel.prompt = "Dodaj"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func open(_ urls: [URL]) {
        guard !phase.isBusy else {
            show("Poczekaj, aż skończę podpisywać.", symbol: "hourglass")
            return
        }
        if case .finished = phase { clearFinished() }
        var skipped: [String] = []
        var added: [Document] = []
        for url in urls.map(\.standardizedFileURL) {
            if documents.contains(where: { $0.url == url }) { continue }
            guard let kind = DocumentInspector.kind(of: url) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            let doc = Document(url: url, kind: kind, anchor: anchorText, output: plan(for: url, excluding: nil))
            documents.append(doc)
            added.append(doc)
            load(doc)
        }
        if let first = added.first {
            selectionID = first.id
            // Files usually arrive from Finder while Podpis is in the background, where the
            // status is not polled: check the card now so the button is right.
            card.refreshSoon()
        }
        if !skipped.isEmpty {
            let list = skipped.prefix(3).joined(separator: ", ") + (skipped.count > 3 ? " i \(skipped.count - 3) inne" : "")
            show("Pominąłem \(list): podpisuję tylko PDF i XML.", symbol: "doc.badge.ellipsis")
        }
    }

    func remove(_ doc: Document) {
        guard !phase.isBusy else { return }
        doc.locateTask?.cancel()
        documents.removeAll { $0.id == doc.id }
        if selectionID == doc.id { selectionID = documents.first?.id }
        replanOutputs()
        if documents.isEmpty { phase = .idle; batchProblem = nil }
    }

    func clearAll() {
        guard !phase.isBusy else { return }
        documents.forEach { $0.locateTask?.cancel() }
        documents.removeAll()
        selectionID = nil
        phase = .idle
        batchProblem = nil
    }

    /// Drops the files that are done, keeping the ones that still need work.
    func clearFinished() {
        documents.removeAll { $0.outcome.signedFile != nil }
        if !documents.contains(where: { $0.id == selectionID }) { selectionID = documents.first?.id }
        phase = .idle
        batchProblem = nil
        replanOutputs()
    }

    private func plan(for url: URL, excluding doc: Document?) -> OutputNaming.Plan {
        let reserved = Set(documents.filter { $0 !== doc }.map { $0.output.url.standardizedFileURL.path })
        return OutputNaming.plan(for: url, reserved: reserved)
    }

    private func replanOutputs() {
        for doc in documents where doc.outcome.signedFile == nil {
            doc.output = plan(for: doc.url, excluding: doc)
        }
    }

    private func load(_ doc: Document) {
        switch doc.kind {
        case .pdf:
            guard let pdf = PDFDocument(url: doc.url) else {
                doc.loadProblem = "Nie da się otworzyć tego PDF-a. Plik jest uszkodzony albo to nie PDF."
                doc.existing = .none
                return
            }
            if pdf.isLocked {
                doc.loadProblem = "Ten PDF jest zabezpieczony hasłem. Podpisz wersję bez hasła."
                doc.existing = .none
                return
            }
            doc.pdf = pdf
            checkExistingPDFSignatures(doc)
            locate(doc)
        case .xml:
            guard let data = try? Data(contentsOf: doc.url) else {
                doc.loadProblem = "Nie da się odczytać tego pliku."
                doc.existing = .none
                return
            }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            doc.xmlText = text
            doc.existing = DocumentInspector.xmlSigners(text).map { .signed(by: $0.isEmpty ? ["nieznany podpisujący"] : $0) } ?? .none
        }
    }

    private func checkExistingPDFSignatures(_ doc: Document) {
        guard let data = try? Data(contentsOf: doc.url, options: .mappedIfSafe),
              DocumentInspector.pdfHasSignature(data) else {
            doc.existing = .none
            return
        }
        Task {
            await cliSlots.acquire()
            let names = (try? await client.verify(doc.url))?.signers ?? []
            await cliSlots.release()
            doc.existing = .signed(by: names.isEmpty ? ["nieznany podpisujący"] : names)
        }
    }

    // MARK: placement

    /// Files opened before the card was read had no name to look for: now that there is one,
    /// look again, unless the user already moved the signature.
    private func relocateUnanchored() {
        let anchor = anchorText
        guard !anchor.isEmpty else { return }
        for doc in documents where doc.kind == .pdf && doc.outcome.signedFile == nil
            && doc.anchor.trimmingCharacters(in: .whitespaces).isEmpty {
            if case .manual = doc.placement { continue }
            doc.anchor = anchor
            locate(doc)
        }
    }

    func locate(_ doc: Document) {
        guard doc.kind == .pdf, let pdf = doc.pdf else { return }
        doc.locateTask?.cancel()
        doc.placement = .locating
        let anchor = doc.anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        // Without an anchor there is nothing to ask the CLI: start from the default spot.
        guard !anchor.isEmpty else {
            doc.placement = fallback(for: doc, pdf: pdf, reason: "Nie wiem, nad jakim tekstem postawić podpis. Przeciągnij podpis na miejsce albo wpisz tekst w polu wyżej.")
            return
        }
        // The user's own anchor first. When the document does not name them, the surname and the
        // usual "podpis" label under a signature line are worth a try before giving up.
        let alternatives = anchor == anchorText
            ? ([anchor.split(separator: " ").last.map(String.init), "podpis", "Podpis"] as [String?])
                .compactMap { $0 }.filter { $0 != anchor }
            : []
        doc.locateTask = Task {
            let result: Placement
            await cliSlots.acquire()
            defer { Task { await cliSlots.release() } }
            guard !Task.isCancelled else { return }
            do {
                let (r, used) = try await firstPlacement(doc.url, anchors: [anchor] + alternatives)
                guard !Task.isCancelled else { return }
                if let rect = r.cgRect, let geo = doc.geometry(page: r.page - 1), let crop = doc.cropBox(page: r.page - 1) {
                    let box = PageGeometry.clamp(geo.signatureBox(fromPoppler: rect), into: crop)
                    result = used == anchor
                        ? .suggested(page: r.page - 1, rect: box, anchor: anchor)
                        : .needsAttention(page: r.page - 1, rect: box,
                                          reason: "Nie znalazłem „\(anchor)”, więc podpis stoi nad „\(used)”.")
                } else {
                    result = fallback(for: doc, pdf: pdf, reason: "Nie udało się odczytać miejsca na podpis.")
                }
            } catch let e as PodpisError {
                guard !Task.isCancelled, e != .cancelled else { return }
                let reason: String
                switch e.code {
                case "brak_kotwicy": reason = "Nie znalazłem „\(anchor)” w tym dokumencie. Przeciągnij podpis na miejsce."
                case "brak_miejsca": reason = "Nad „\(anchor)” jest mało miejsca. Sprawdź, czy podpis nie zasłania tekstu."
                default: reason = "Nie udało się wyznaczyć miejsca (\(e.advice.title.lowercased())). Ustaw podpis ręcznie."
                }
                result = fallback(for: doc, pdf: pdf, reason: reason)
            } catch {
                return
            }
            doc.placement = result
        }
    }

    /// Tries the anchors in order; a missing anchor moves on to the next one, any other
    /// error (or the last miss) is reported for the first anchor, the one the user expects.
    private func firstPlacement(_ pdf: URL, anchors: [String]) async throws -> (PlacementResponse, String) {
        var firstMiss: PodpisError?
        for candidate in anchors {
            do {
                return (try await client.place(pdf: pdf, anchor: candidate), candidate)
            } catch let e as PodpisError where e.code == "brak_kotwicy" {
                firstMiss = firstMiss ?? e
            }
        }
        throw firstMiss ?? PodpisError.cli(code: "brak_kotwicy", message: "")
    }

    /// A spot to start from when the CLI found none: right above the anchor if PDFKit sees
    /// it, otherwise the lower right of the last page.
    private func fallback(for doc: Document, pdf: PDFDocument, reason: String) -> Placement {
        let size = art.defaultSize
        let anchor = doc.anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !anchor.isEmpty,
           let hit = pdf.findString(anchor, withOptions: [.caseInsensitive]).last,
           let page = hit.pages.last {
            let index = pdf.index(for: page)
            let b = hit.bounds(for: page)
            let box = CGRect(x: b.midX - size.width / 2, y: b.maxY + 1.5, width: size.width, height: size.height)
            return .needsAttention(page: index, rect: PageGeometry.clamp(box, into: page.bounds(for: .cropBox)).roundedToPoints(),
                                   reason: reason)
        }
        let index = max(0, pdf.pageCount - 1)
        let crop = pdf.page(at: index)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let box = CGRect(x: crop.maxX - size.width - 60, y: crop.minY + 110, width: size.width, height: size.height)
        return .needsAttention(page: index, rect: PageGeometry.clamp(box, into: crop).roundedToPoints(), reason: reason)
    }

    func moveStamp(_ doc: Document, page: Int, rect: CGRect) {
        guard doc.outcome.signedFile == nil, !phase.isBusy else { return }
        let crop = doc.cropBox(page: page) ?? rect
        doc.placement = .manual(page: page, rect: PageGeometry.clamp(rect, into: crop).roundedToPoints())
    }

    func applyAnchorToAll(from doc: Document) {
        for other in documents where other.kind == .pdf && other.outcome.signedFile == nil {
            other.anchor = doc.anchor
            locate(other)
        }
    }

    // MARK: signing

    /// Return in the main window.
    func requestSign() {
        guard canSign, let info = card.state.info else {
            if !phase.isBusy { NSSound.beep() }
            return
        }
        batchProblem = nil
        if info.pin.lastTry {
            pinRequest = makePinRequest(mode: .lastTry, note: nil)
            return
        }
        if vault.hasPIN {
            phase = .authenticating
            let count = queue.count
            let reason = count == 1 ? "odczytać zapamiętany PIN i podpisać dokument" : "odczytać zapamiętany PIN i podpisać \(count) \(Self.plural(count, "dokument", "dokumenty", "dokumentów"))"
            Task {
                do {
                    let pin = try await vault.unlock(reason: reason)
                    await runBatch(pin: pin, fromVault: true, allowLastTry: false, remember: false)
                } catch PinVault.Failure.cancelled {
                    phase = .idle
                } catch PinVault.Failure.typePIN(let note) {
                    phase = .idle
                    pinRequest = makePinRequest(mode: info.pin.lowTries ? .lowTries : .normal, note: note)
                } catch {
                    phase = .idle
                }
            }
            return
        }
        pinRequest = makePinRequest(mode: info.pin.lowTries ? .lowTries : .normal, note: nil)
    }

    func submitPIN(_ text: String, remember: Bool, lastTryConfirmed: Bool) {
        guard let request = pinRequest, let pin = PinSecret(text) else { return }
        if request.mode == .lastTry && !lastTryConfirmed { return }
        pinRequest = nil
        Task {
            await runBatch(pin: pin, fromVault: false, allowLastTry: request.mode == .lastTry,
                           remember: remember && request.canRemember)
        }
    }

    func cancelPIN() {
        pinRequest = nil
    }

    /// Esc in the main window.
    func cancel() {
        switch phase {
        case .signing:
            stopAfterCurrent = true
        case .finished:
            clearFinished()
        case .idle, .authenticating:
            batchProblem = nil
        }
    }

    private func makePinRequest(mode: PinRequest.Mode, note: String?) -> PinRequest {
        let lines = queue.map { doc -> PinRequest.Line in
            switch doc.kind {
            case .xml:
                return .init(name: doc.name, detail: "XML, podpis XAdES", attention: false)
            case .pdf:
                let page = (doc.placement.spot?.page ?? 0) + 1
                if case .needsAttention = doc.placement {
                    return .init(name: doc.name, detail: "strona \(page), miejsce do sprawdzenia", attention: true)
                }
                return .init(name: doc.name, detail: "strona \(page)", attention: false)
            }
        }
        return PinRequest(mode: mode, note: note, lines: lines, signer: holder,
                          canRemember: mode != .lastTry && !vault.hasPIN && vault.biometryAvailable)
    }

    private func runBatch(pin: PinSecret, fromVault: Bool, allowLastTry: Bool, remember: Bool) async {
        defer { pin.wipe() }
        let docs = queue
        guard !docs.isEmpty else { phase = .idle; return }
        stopAfterCurrent = false
        batchProblem = nil
        await card.pauseAndDrain()
        var signed = 0, failed = 0, reopenLastTry = false

        batch: for (i, doc) in docs.enumerated() {
            if stopAfterCurrent { break }
            phase = .signing(index: i + 1, total: docs.count, name: doc.name)
            selectionID = doc.id
            doc.output = plan(for: doc.url, excluding: doc)
            doc.outcome = .signing
            do {
                let file: SignedFile
                switch doc.kind {
                case .pdf:
                    guard let spot = doc.placement.spot else { doc.outcome = .pending; continue }
                    file = try await client.signPDF(doc.url, page: spot.page + 1, rect: spot.rect,
                                                    output: doc.output.url, pin: pin, allowLastTry: allowLastTry)
                case .xml:
                    file = try await client.signXML(doc.url, output: doc.output.url, pin: pin, allowLastTry: allowLastTry,
                                                    addAnother: doc.existing.signers != nil)
                }
                signed += 1
                finishSigned(doc, file)
            } catch let e as PodpisError {
                if e.stopsBatch {
                    doc.outcome = .pending
                    var advice = e.advice
                    if e.code == "zly_pin" && fromVault {
                        vault.forget()
                        advice = Advice(title: advice.title,
                                        message: "Zapamiętany PIN nie pasuje do karty, więc go usunąłem. Karta odjęła jedną próbę.",
                                        nextStep: "Wpisz PIN ręcznie.", symbol: advice.symbol, tone: advice.tone, detail: nil)
                    }
                    batchProblem = advice
                    reopenLastTry = e.code == "ostatnia_proba"
                    break batch
                }
                doc.outcome = .failed(e)
                failed += 1
                // A crash or an unknown error before any file went through leaves it open
                // whether the card took the PIN; reusing it could cost a try, so stop here.
                if signed == 0 && !e.isAfterLogin && docs.count > i + 1 {
                    batchProblem = Advice(
                        title: "Przerwałem pozostałe pliki",
                        message: "Pierwszy plik się nie podpisał i nie wiem, czy PIN dotarł do karty, więc nie użyłem go ponownie.",
                        nextStep: "Sprawdź szczegóły błędu i spróbuj jeszcze raz.",
                        symbol: "pause.circle.fill", tone: .warning, detail: nil)
                    break batch
                }
            } catch {
                doc.outcome = .failed(.unexpected(exitCode: -1, detail: "\(error)"))
                failed += 1
            }
        }

        if remember && signed > 0 {
            vault.save(pin)
            if vault.hasPIN { show("PIN zapamiętany. Następnym razem wystarczy Touch ID.", symbol: "touchid") }
        }
        stopAfterCurrent = false
        card.resume()
        await card.refreshNow()
        phase = signed + failed > 0 ? .finished(signed: signed, failed: failed) : .idle
        if let first = docs.first(where: { $0.outcome.signedFile != nil }) ?? docs.first(where: {
            if case .failed = $0.outcome { return true } else { return false }
        }) {
            selectionID = first.id
        }
        if reopenLastTry, card.state.info?.pin.lastTry == true {
            batchProblem = nil
            pinRequest = makePinRequest(mode: .lastTry, note: nil)
        }
    }

    private func finishSigned(_ doc: Document, _ file: SignedFile) {
        doc.signedPDF = doc.kind == .pdf ? PDFDocument(url: file.url) : nil
        if doc.kind == .xml, let check = file.xmlCheck {
            doc.outcome = .signed(file, check.ok ? .passed("Podpis XML sprawdzony (xmlsec1)")
                                               : .failed("xmlsec1 nie potwierdził podpisu"))
            return
        }
        doc.outcome = .signed(file, .checking)
        Task {
            let verification: Verification
            do {
                let v = try await client.verify(file.url)
                if v.newestCoversWholeFile {
                    verification = .passed("Podpis nienaruszony, obejmuje cały plik")
                } else if v.signatures?.last?.intact == true {
                    verification = .failed("Podpis jest, ale nie obejmuje całego pliku")
                } else {
                    verification = .failed("Weryfikacja nie potwierdziła podpisu")
                }
            } catch let e as PodpisError {
                verification = .failed("Nie udało się sprawdzić: \(e.advice.title.lowercased())")
            } catch {
                verification = .failed("Nie udało się sprawdzić podpisu")
            }
            if case .signed(let f, _) = doc.outcome, f == file {
                doc.outcome = .signed(file, verification)
            }
        }
    }

    // MARK: helpers

    func show(_ text: String, symbol: String) {
        let t = Toast(text: text, symbol: symbol)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast?.id == t.id { toast = nil }
        }
    }

    nonisolated static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if n == 1 { return one }
        let d = n % 10, t = n % 100
        return (2...4).contains(d) && !(12...14).contains(t) ? few : many
    }
}

/// At most `limit` CLI helpers at once, so dropping ten PDFs does not start ten renderers.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
