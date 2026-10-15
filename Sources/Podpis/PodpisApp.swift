import AppKit
import SwiftUI

@main
struct PodpisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Podpis", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands { PodpisCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct PodpisCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Otwórz…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
                .disabled(model.phase.isBusy)
        }
        CommandGroup(after: .newItem) {
            Button("Podpisz") { model.requestSign() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSign)
            Divider()
            Button("Usuń z listy") {
                if let doc = model.selected { model.remove(doc) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selected == nil || model.phase.isBusy)
            Button("Wyczyść listę") { model.clearAll() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.documents.isEmpty || model.phase.isBusy)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // For screenshots of both themes without touching the system setting.
        switch ProcessInfo.processInfo.environment["PODPIS_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    /// Files dropped on the Dock icon, opened with "Otwórz za pomocą" or `open -a Podpis`.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.openWhenReady(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.phase.isBusy else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Trwa podpisywanie"
            alert.informativeText = "Poczekaj, aż skończę bieżący plik. Przerwanie w trakcie mogłoby zostawić niedokończony plik."
            alert.addButton(withTitle: "Poczekam")
            alert.runModal()
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("podpis-grafika", isDirectory: true))
    }
}
