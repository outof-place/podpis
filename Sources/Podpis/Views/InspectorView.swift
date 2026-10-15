import AppKit
import PodpisCore
import SwiftUI

/// Right column: the files, where the signature goes, who signs, and the sign button.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DocumentsSection()
                if let doc = model.selected, doc.loadProblem == nil {
                    ExistingSignaturesNote(doc: doc)
                    if doc.kind == .pdf && doc.outcome.signedFile == nil && !doc.isSkipped(holder: model.holder) {
                        PlacementSection(doc: doc, editing: $editing)
                    }
                    if !doc.isSkipped(holder: model.holder) {
                        OutputSection(doc: doc)
                    }
                }
                if model.documents.contains(where: { $0.outcome.signedFile == nil }) {
                    SignerSection()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SignBar(editing: editing)
        }
    }
}

// MARK: files

struct DocumentsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: model.documents.count == 1 ? "Dokument" : "Dokumenty (\(model.documents.count))",
                          trailing: AnyView(
                            Button { model.presentOpenPanel() } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless)
                                .help("Dodaj pliki (⌘O)")
                                .disabled(model.phase.isBusy)))
            VStack(spacing: 2) {
                ForEach(model.documents) { doc in
                    DocumentRow(doc: doc, selected: doc.id == model.selected?.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectionID = doc.id }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.selectionID = doc.id }
                        .contextMenu {
                            Button("Pokaż oryginał w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
                            if let f = doc.outcome.signedFile {
                                Button("Pokaż podpisany w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                            }
                            Divider()
                            Button("Usuń z listy") { model.remove(doc) }.disabled(model.phase.isBusy)
                        }
                }
            }
        }
    }
}

struct DocumentRow: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    let doc: Document
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: doc.kind == .pdf ? "doc.richtext.fill" : "chevron.left.forwardslash.chevron.right")
                .font(.title3)
                .foregroundStyle(doc.kind == .pdf ? Color.red.opacity(0.8) : Color.ink)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.05) : .clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailing: some View {
        switch doc.outcome {
        case .signing:
            ProgressView().controlSize(.small)
        case .signed(_, let v):
            Image(systemName: v == .checking ? "checkmark.circle" : (isFailed(v) ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                .foregroundStyle(isFailed(v) ? .red : .green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .pending:
            if doc.loadProblem != nil {
                Image(systemName: "nosign").foregroundStyle(.secondary)
            } else if doc.kind == .pdf && doc.placement.isLocating || doc.existing == .checking {
                ProgressView().controlSize(.small)
            } else if hovering && !model.phase.isBusy {
                Button { model.remove(doc) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Usuń z listy")
            } else if !doc.isReadyToSign(holder: model.holder) {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    .help("Ten plik pominę")
            } else if case .needsAttention = doc.placement {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func isFailed(_ v: Verification) -> Bool {
        if case .failed = v { return true }
        return false
    }

    private var subtitle: String {
        if let p = doc.loadProblem { return p }
        switch doc.outcome {
        case .signing: return "Podpisuję…"
        case .signed(let f, _): return f.url.lastPathComponent
        case .failed(let e): return e.advice.title
        case .pending: break
        }
        if doc.isSkipped(holder: model.holder) { return "Już podpisany przez Ciebie, pominę" }
        if doc.kind == .xml { return "XML, podpis XAdES" }
        switch doc.placement {
        case .locating: return "Szukam miejsca na podpis…"
        case .suggested(let p, _, _): return "\(doc.pageCount) str. · podpis na stronie \(p + 1)"
        case .manual(let p, _): return "\(doc.pageCount) str. · podpis ręcznie na stronie \(p + 1)"
        case .needsAttention(let p, _, _): return "Sprawdź miejsce podpisu (strona \(p + 1))"
        }
    }

    private var subtitleColor: Color {
        switch doc.outcome {
        case .failed: return .red
        case .signed: return .green
        default: break
        }
        if !doc.isReadyToSign(holder: model.holder) { return .secondary }
        if case .needsAttention = doc.placement, doc.kind == .pdf { return .orange }
        return .secondary
    }
}

// MARK: placement

struct PlacementSection: View {
    @Environment(AppModel.self) private var model
    @Bindable var doc: Document
    var editing: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Miejsce podpisu")
            status
            HStack(spacing: 6) {
                TextField("Tekst pod podpisem", text: $doc.anchor)
                    .textFieldStyle(.roundedBorder)
                    .focused(editing)
                    .onSubmit { model.locate(doc); editing.wrappedValue = false }
                    .help("Podpis stanie nad tym tekstem, zwykle nad Twoim imieniem i nazwiskiem.")
                Button("Szukaj") { model.locate(doc); editing.wrappedValue = false }
                    .disabled(doc.anchor.trimmingCharacters(in: .whitespaces).isEmpty || model.phase.isBusy)
            }
            HStack(spacing: 14) {
                if case .manual = doc.placement {
                    Button("Przywróć sugerowane miejsce") { model.locate(doc) }
                        .buttonStyle(.link)
                }
                if model.documents.filter({ $0.kind == .pdf && $0.outcome.signedFile == nil }).count > 1 {
                    Button("Ten tekst we wszystkich PDF") { model.applyAnchorToAll(from: doc) }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
            Text("Przeciągnij podpis na stronie albo kliknij dwukrotnie w nowe miejsce. Opcja i strzałki przesuwają go o punkt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        switch doc.placement {
        case .locating:
            Label("Szukam „\(doc.anchor)”…", systemImage: "text.magnifyingglass")
                .foregroundStyle(.secondary)
        case .suggested(let p, _, let anchor):
            Label("Strona \(p + 1), nad „\(anchor)”", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.primary)
                .symbolRenderingMode(.multicolor)
        case .manual(let p, _):
            Label("Strona \(p + 1), ustawione ręcznie", systemImage: "hand.point.up.left.fill")
        case .needsAttention(let p, _, let reason):
            NoteCard(tone: .warning, symbol: "exclamationmark.triangle.fill") {
                Text(reason).font(.callout)
                Text("Podpis stoi na stronie \(p + 1). Sprawdź go przed podpisaniem.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ExistingSignaturesNote: View {
    @Environment(AppModel.self) private var model
    @Bindable var doc: Document

    var body: some View {
        if let signers = doc.existing.signers, doc.outcome.signedFile == nil {
            let mine = doc.signedByHolder(model.holder)
            NoteCard(tone: mine ? .warning : .info, symbol: "signature") {
                Text(mine ? "Ten plik już podpisałeś" : "Plik ma już podpis")
                    .font(.callout.weight(.semibold))
                Text("Podpisali: " + signers.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if mine {
                    Toggle("Dołóż kolejny podpis", isOn: $doc.addAnother)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                } else {
                    Text("Twój podpis dołożę jako kolejny, poprzednie zostaną ważne.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct OutputSection: View {
    let doc: Document

    var body: some View {
        if doc.outcome.signedFile == nil {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Zapis")
                Label {
                    Text(doc.output.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "arrow.down.doc")
                }
                .font(.callout)
                Text(where_)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var where_: String {
        var parts: [String] = []
        if doc.output.movedToFallback {
            parts.append("Do folderu oryginału nie da się zapisać, więc trafi do Pobranych.")
        } else {
            parts.append("Obok oryginału, w folderze \(doc.url.deletingLastPathComponent().lastPathComponent). Oryginał zostaje bez zmian.")
        }
        if doc.output.plainNameTaken {
            parts.append("Wersja „-podpisany” już tam jest, więc dodałem numer.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: signer

struct SignerSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Podpisujesz jako")
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.holder).font(.headline)
                    if let info = model.card.state.info {
                        Text(info.qualified ? "Podpis kwalifikowany · ważny do \(info.validUntilText)"
                                            : "Certyfikat nie jest kwalifikowany")
                            .font(.caption)
                            .foregroundStyle(info.qualified && !info.expiresSoon ? Color.secondary : Color.orange)
                    } else {
                        Text("Dane z karty pojawią się po jej włożeniu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: sign bar

struct SignBar: View {
    @Environment(AppModel.self) private var model
    let editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = model.batchProblem {
                NoteCard(tone: problem.tone == .failure ? .failure : .warning, symbol: problem.symbol) {
                    Text(problem.title).font(.callout.weight(.semibold))
                    Text(problem.message).font(.callout).foregroundStyle(.secondary)
                    if let next = problem.nextStep { Text(next).font(.callout) }
                }
            }
            switch model.phase {
            case .signing(let index, let total, let name):
                signing(index: index, total: total, name: name)
            case .authenticating:
                Label("Dotknij Touch ID, żeby podpisać", systemImage: "touchid")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .symbolEffect(.pulse)
                    .frame(maxWidth: .infinity, minHeight: 44)
            case .finished(let signed, let failed) where model.queue.isEmpty:
                finished(signed: signed, failed: failed)
            default:
                ready
            }
        }
        .padding(16)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.smooth(duration: 0.25), value: model.phase)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let blocker = model.signBlocker {
                Label(blocker, systemImage: blockerSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.requestSign()
            } label: {
                Label(signTitle, systemImage: model.vault.hasPIN && model.card.state.info?.pin.lastTry != true ? "touchid" : "signature")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(!model.canSign)
            .keyboardShortcut(editing ? nil : .defaultAction)
            HStack {
                Text(model.vault.hasPIN ? "PIN zapamiętany z Touch ID." : "Enter podpisuje, Esc przerywa.")
                Spacer()
                if model.vault.hasPIN {
                    Button("Zapomnij PIN") { model.vault.forget() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var blockerSymbol: String {
        switch model.card.state {
        case .noReader: return "cable.connector"
        case .noCard: return "creditcard"
        case .pinLocked: return "lock.slash"
        case .problem: return "exclamationmark.triangle"
        default: return "info.circle"
        }
    }

    private var signTitle: String {
        let n = model.queue.count
        if n <= 1 { return "Podpisz" }
        return "Podpisz \(n) \(AppModel.plural(n, "plik", "pliki", "plików"))"
    }

    private func signing(index: Int, total: Int, name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(total > 1 ? "Podpisuję \(index) z \(total)" : "Podpisuję")
                    .font(.headline)
                Spacer()
                if model.stopAfterCurrent {
                    Text("Zatrzymam po tym pliku").font(.caption).foregroundStyle(.secondary)
                } else if total > 1 && index < total {
                    Button("Przerwij po tym pliku") { model.cancel() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            ProgressView(value: Double(index - 1) + 0.5, total: Double(total))
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 44)
    }

    private func finished(signed: Int, failed: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: failed == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(failed == 0 ? .green : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(failed == 0
                         ? (signed == 1 ? "Podpisano" : "Podpisano \(signed) \(AppModel.plural(signed, "plik", "pliki", "plików"))")
                         : "Podpisano \(signed), nie udało się \(failed)")
                        .font(.headline)
                    Text("Podpisane pliki leżą obok oryginałów.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                let files = model.documents.compactMap { $0.outcome.signedFile?.url }
                Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                    .disabled(files.isEmpty)
                Spacer()
                Button("Nowe dokumenty") { model.clearFinished() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(editing ? nil : .defaultAction)
            }
            .controlSize(.large)
        }
    }
}
