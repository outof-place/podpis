import AppKit
import SwiftUI

extension Color {
    /// The navy of the signature ink, lifted in dark mode so it stays readable.
    static let ink = Color(nsColor: NSColor(name: "ink") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.62, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.149, green: 0.188, blue: 0.494, alpha: 1)
    })
}

extension View {
    /// Controls floating over a PDF page sit on white paper in both modes. Dark mode text
    /// on glass over paper is unreadable, so they take the light look there.
    @ViewBuilder func onPaper(_ isPaper: Bool = true) -> some View {
        if isPaper { environment(\.colorScheme, .light) } else { self }
    }
}

/// A rounded card used for notes in the inspector and banners over the page.
struct NoteCard<Content: View>: View {
    enum Tone { case info, warning, failure, success }

    let tone: Tone
    let symbol: String
    @ViewBuilder var content: Content

    var color: Color {
        switch tone {
        case .info: return .ink
        case .warning: return .orange
        case .failure: return .red
        case .success: return .green
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.body.weight(.semibold))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.18)))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

extension View {
    /// Zero-size button that gives the window a keyboard shortcut.
    func shortcut(_ key: KeyboardShortcut?, action: @escaping () -> Void) -> some View {
        background {
            Button("", action: action)
                .keyboardShortcut(key)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
