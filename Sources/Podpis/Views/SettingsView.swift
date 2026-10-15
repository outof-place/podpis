import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Miejsce podpisu") {
                TextField("Tekst pod podpisem", text: $model.defaultAnchor, prompt: Text("Domyślnie: imię i nazwisko z karty"))
                Text("Podpis staje nad tym tekstem w każdym nowym PDF-ie. Zwykle to Twoje imię i nazwisko.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Touch ID") {
                LabeledContent("Zapamiętany PIN") {
                    if model.vault.hasPIN {
                        Button("Zapomnij PIN") { model.vault.forget() }
                    } else {
                        Text("brak").foregroundStyle(.secondary)
                    }
                }
                Text(model.vault.biometryAvailable
                     ? "PIN zapamiętasz w okienku PIN-u. Leży w pęku kluczy i wychodzi z niego tylko po Touch ID."
                     : "Touch ID jest teraz niedostępny (na przykład przy zamkniętej klapie).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Program podpisz") {
                LabeledContent("Ścieżka") {
                    Text(model.client.executable.path)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text("Inną ścieżkę ustawisz zmienną środowiskową PODPIS_CLI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
