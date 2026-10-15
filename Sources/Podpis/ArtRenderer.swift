import AppKit
import Observation
import PodpisCore

/// The exact signature art from `podpisz grafika`, cached per box size and name, for the
/// true-size preview on the page. Re-rendered once a minute while visible, because the
/// caption carries the date and time.
@MainActor @Observable
final class ArtRenderer {
    struct Key: Hashable {
        let name: String
        let width: Int
        let height: Int
    }

    private(set) var images: [Key: NSImage] = [:]
    private(set) var failed = false
    /// Default box, as the CLI reports it (140 x 48 today).
    private(set) var defaultSize = CGSize(width: 140, height: 48)
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private var renderedAt: [Key: Date] = [:]
    @ObservationIgnored private let client: PodpisClient
    @ObservationIgnored private let folder: URL

    init(client: PodpisClient) {
        self.client = client
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("podpis-grafika", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Learns the default size from the CLI once, so a CLI change does not need an app change.
    func learnDefaults() {
        Task {
            let out = folder.appendingPathComponent("rozmiar-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: out) }
            if let r = try? await client.art(output: out, name: "", width: nil, height: nil) {
                defaultSize = CGSize(width: r.width, height: r.height)
            }
        }
    }

    func image(for key: Key) -> NSImage? {
        images[key]
    }

    /// Renders `key` unless it was rendered in the last minute; the old image stays until the new one lands.
    func ensure(_ key: Key) {
        // A failed render is not retried for a minute either, so a broken CLI cannot spin.
        let recent = renderedAt[key].map { Date().timeIntervalSince($0) < 60 } ?? false
        guard !recent, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            let out = folder.appendingPathComponent("podpis-\(key.width)x\(key.height)-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: out) }
            do {
                let r = try await client.art(output: out, name: key.name, width: key.width, height: key.height)
                guard let img = NSImage(contentsOf: URL(fileURLWithPath: r.file)) else { throw PodpisError.cancelled }
                img.size = CGSize(width: key.width, height: key.height)
                images[key] = img
                renderedAt[key] = Date()
                failed = false
            } catch {
                failed = true
                renderedAt[key] = Date()
            }
        }
    }
}
