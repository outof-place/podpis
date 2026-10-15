import PodpisCore
import SwiftUI

/// The live reader and card status in the toolbar; click for certificate details.
struct CardStatusChip: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        let look = Look(model.card.state)
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(look.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: look.color.opacity(0.6), radius: look.glow ? 3 : 0)
                Text(look.title)
                    .font(.callout.weight(.medium))
                if let detail = look.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.3), value: model.card.state)
        }
        .help("Czytnik i karta")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            CardDetails()
                .environment(model)
        }
    }

    struct Look {
        let color: Color
        let title: String
        let detail: String?
        let glow: Bool

        init(_ state: CardState) {
            switch state {
            case .checking:
                (color, title, detail, glow) = (.secondary, "Sprawdzam kartę…", nil, false)
            case .noReader:
                (color, title, detail, glow) = (.secondary, "Brak czytnika", nil, false)
            case .noCard:
                (color, title, detail, glow) = (.orange, "Włóż kartę", nil, false)
            case .pinLocked:
                (color, title, detail, glow) = (.red, "PIN zablokowany", nil, false)
            case .problem(let e):
                (color, title, detail, glow) = (.red, e.advice.title, nil, false)
            case .ready(let i):
                if i.isExpired {
                    (color, title, detail, glow) = (.red, "Certyfikat wygasł", i.validUntilText, false)
                } else if i.pin.lastTry {
                    (color, title, detail, glow) = (.red, i.name, "ostatnia próba PIN-u", true)
                } else if i.expiresSoon, let d = i.daysLeft {
                    (color, title, detail, glow) = (.orange, i.name, "wygasa za \(d) \(AppModel.plural(d, "dzień", "dni", "dni"))", true)
                } else if i.pin.lowTries {
                    (color, title, detail, glow) = (.orange, i.name, "mało prób PIN-u", true)
                } else {
                    (color, title, detail, glow) = (.green, i.name, "do \(i.validUntilText)", true)
                }
            }
        }
    }
}

struct CardDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let info = model.card.state.info {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Posiadacz", info.name)
                    if let t = info.title { row("Tytuł", t) }
                    if let p = info.maskedPesel { row("PESEL", p) }
                    if let i = info.issuer { row("Wystawca", i) }
                    row("Ważny do", info.validUntilText + (info.daysLeft.map { $0 >= 0 ? " (za \($0) \(AppModel.plural($0, "dzień", "dni", "dni")))" : "" } ?? ""))
                    row("Rodzaj", info.qualified ? "kwalifikowany" : "niekwalifikowany")
                    if let n = info.cardNumber { row("Karta", n) }
                    row("PIN", info.pin.lastTry ? "ostatnia próba" : (info.pin.lowTries ? "mało prób" : "w porządku"))
                }
                .font(.callout)
            } else if let advice = advice {
                VStack(alignment: .leading, spacing: 4) {
                    Text(advice.message).font(.callout)
                    if let next = advice.nextStep { Text(next).font(.callout).foregroundStyle(.secondary) }
                    if let d = advice.detail {
                        Text(d).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if let at = model.card.lastChecked {
                    Text("Sprawdzono \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sprawdź teraz") { model.card.refreshSoon() }
                    .controlSize(.small)
            }
            Text("Status odświeża się co 2 sekundy, gdy aplikacja jest aktywna. Czytnik możesz podłączyć w każdej chwili.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340)
    }

    private var advice: Advice? {
        switch model.card.state {
        case .noReader: return PodpisError.cli(code: "brak_czytnika", message: "").advice
        case .noCard: return PodpisError.cli(code: "brak_karty", message: "").advice
        case .pinLocked: return PodpisError.cli(code: "pin_zablokowany", message: "").advice
        case .problem(let e): return e.advice
        default: return nil
        }
    }

    private var header: some View {
        let look = CardStatusChip.Look(model.card.state)
        return HStack(spacing: 12) {
            Image(systemName: model.card.state.info == nil ? "creditcard.trianglebadge.exclamationmark" : "creditcard.fill")
                .font(.title)
                .foregroundStyle(look.color == .secondary ? Color.ink : look.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.card.state.info == nil ? look.title : "Karta gotowa do podpisu")
                    .font(.headline)
                Text(model.client.executable.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
