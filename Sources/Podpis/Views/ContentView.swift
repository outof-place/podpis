import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.documents.isEmpty {
                EmptyStateView(dropTargeted: dropTargeted)
                    .transition(.opacity)
            } else {
                DocumentPane()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: model.documents.isEmpty)
        .frame(minWidth: 640, minHeight: 560)
        .inspector(isPresented: .constant(!model.documents.isEmpty)) {
            InspectorView()
                .inspectorColumnWidth(min: 310, ideal: 350, max: 460)
        }
        .toolbar {
            if model.isTestMode {
                ToolbarItem(placement: .primaryAction) {
                    Label("Tryb testowy", systemImage: "testtube.2")
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .help("Podpis używa \(model.client.executable.path) zamiast prawdziwego programu podpisz. PIN nie trafi do karty.")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                CardStatusChip()
            }
        }
        .navigationTitle("Podpis")
        .navigationSubtitle(model.selected?.name ?? "")
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !model.documents.isEmpty {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .sheet(item: $model.pinRequest) { request in
            PinSheet(request: request)
                .environment(model)
        }
        .windowDismissBehavior(model.phase.isBusy ? .disabled : .automatic)
        .shortcut(.cancelAction) { model.cancel() }
        .tint(.ink)
    }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.ink, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label("Upuść, żeby dodać do podpisu", systemImage: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.text, systemImage: toast.symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 560)
    }
}
