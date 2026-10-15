import PodpisCore
import SwiftUI

/// Asks for the card PIN once for the whole batch. The PIN goes to the CLI on stdin and is
/// wiped afterwards; it is stored only when the user ticks Touch ID and the signature worked.
struct PinSheet: View {
    @Environment(AppModel.self) private var model
    let request: PinRequest
    @State private var pin = ""
    @State private var remember = false
    @State private var lastTryConfirmed = false
    @FocusState private var focused: Bool

    private var valid: Bool { PinSecret.isValid(pin) }
    private var canSubmit: Bool { valid && (request.mode != .lastTry || lastTryConfirmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: request.mode == .lastTry ? "exclamationmark.lock.fill" : "lock.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(request.mode == .lastTry ? Color.red : Color.ink)
                    .frame(width: 48, height: 48)
                    .background((request.mode == .lastTry ? Color.red : Color.ink).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("PIN karty kwalifikowanej")
                        .font(.title3.weight(.semibold))
                    Text(request.signer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(request.lines) { line in
                    HStack(spacing: 8) {
                        Image(systemName: line.attention ? "exclamationmark.triangle.fill" : "doc.text")
                            .foregroundStyle(line.attention ? .orange : .secondary)
                            .frame(width: 16)
                        Text(line.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(line.detail)
                            .foregroundStyle(line.attention ? .orange : .secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if model.isTestMode {
                NoteCard(tone: .warning, symbol: "testtube.2") {
                    Text("Tryb testowy: fałszywy program podpisz, nie wpisuj prawdziwego PIN-u.").font(.callout)
                }
            }
            if let note = request.note {
                NoteCard(tone: .info, symbol: "info.circle.fill") {
                    Text(note).font(.callout)
                }
            }
            switch request.mode {
            case .lastTry:
                NoteCard(tone: .failure, symbol: "exclamationmark.octagon.fill") {
                    Text("Karta ma ostatnią próbę PIN-u").font(.callout.weight(.semibold))
                    Text("Błędny PIN zablokuje kartę, a odblokujesz ją tylko kodem PUK. Touch ID tym razem nie zadziała.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Jestem pewien tego PIN-u, użyj ostatniej próby", isOn: $lastTryConfirmed)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .padding(.top, 2)
                }
            case .lowTries:
                NoteCard(tone: .warning, symbol: "exclamationmark.triangle.fill") {
                    Text("Karta zgłasza mało prób PIN-u. Wpisz go uważnie.").font(.callout)
                }
            case .normal:
                EmptyView()
            }

            VStack(alignment: .leading, spacing: 6) {
                SecureField("PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospacedDigit())
                    .focused($focused)
                    .onChange(of: pin) { _, new in
                        let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(12))
                        if digits != new { pin = digits }
                    }
                    .onSubmit(submit)
                Text(pin.isEmpty || valid ? "Same cyfry, od 4 do 12." : "PIN ma od 4 do 12 cyfr.")
                    .font(.caption)
                    .foregroundStyle(pin.isEmpty || valid ? Color.secondary : Color.orange)
            }

            if request.canRemember {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: $remember) {
                        Label("Zapamiętaj PIN z Touch ID", systemImage: "touchid")
                    }
                    .toggleStyle(.checkbox)
                    Text("Zapiszę go w pęku kluczy dopiero, gdy podpis się uda. Potem wystarczy dotknąć czujnika.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }

            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) {
                    pin = ""
                    model.cancelPIN()
                }
                .keyboardShortcut(.cancelAction)
                Button(request.mode == .lastTry ? "Podpisz ostatnią próbą" : "Podpisz", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(request.mode == .lastTry ? .red : .ink)
                    .disabled(!canSubmit)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func submit() {
        guard canSubmit else { return }
        let typed = pin
        pin = ""
        model.submitPIN(typed, remember: remember, lastTryConfirmed: lastTryConfirmed)
    }
}
