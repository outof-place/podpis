import PodpisCore
import SwiftUI

/// First screen: one big target for files, and the card status in words.
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    let dropTargeted: Bool

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.ink.opacity(dropTargeted ? 0.18 : 0.1))
                    .frame(width: 128, height: 128)
                Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "signature")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .contentTransition(.symbolEffect(.replace))
            }
            .scaleEffect(dropTargeted ? 1.06 : 1)
            .animation(.spring(duration: 0.3), value: dropTargeted)

            VStack(spacing: 8) {
                Text("Upuść dokumenty do podpisu")
                    .font(.largeTitle.weight(.semibold))
                Text("PDF dostanie Twój podpis na stronie, XML podpis XAdES.\nKilka plików naraz podpiszesz jednym PIN-em.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Wybierz pliki…", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut("o")

            CardHint()
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(dropTargeted ? Color.ink : Color.secondary.opacity(0.28),
                              style: StrokeStyle(lineWidth: dropTargeted ? 3 : 1.5, dash: [9, 7]))
                .background(Color.ink.opacity(dropTargeted ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(24)
        }
    }
}

/// One line about the reader and card, so you know before dropping anything.
struct CardHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (symbol, color, text) = content
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .animation(.default, value: model.card.state)
    }

    private var content: (String, Color, String) {
        switch model.card.state {
        case .checking: return ("ellipsis.circle", .secondary, "Sprawdzam czytnik i kartę…")
        case .noReader: return ("cable.connector", .orange, "Zanim podpiszesz, podłącz czytnik i włóż kartę.")
        case .noCard: return ("creditcard", .orange, "Czytnik jest. Włóż kartę, zanim podpiszesz.")
        case .pinLocked: return ("lock.slash.fill", .red, "PIN karty jest zablokowany. Odblokuj go kodem PUK.")
        case .problem(let e): return ("exclamationmark.triangle.fill", .red, e.advice.title)
        case .ready(let info):
            if info.isExpired { return ("xmark.seal.fill", .red, "Certyfikat wygasł \(info.validUntilText).") }
            return ("checkmark.circle.fill", .green, "Karta gotowa: \(info.name), certyfikat ważny do \(info.validUntilText).")
        }
    }
}
