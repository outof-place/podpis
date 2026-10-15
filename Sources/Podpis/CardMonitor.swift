import AppKit
import Observation
import PodpisCore

/// Polls `podpisz status` every 2 s while the app is active, and at once on activation,
/// so plugging the reader in just turns the chip green. Paused while a signature runs:
/// the card should talk to one process at a time.
@MainActor @Observable
final class CardMonitor {
    private(set) var state: CardState = .checking
    private(set) var lastChecked: Date?
    private var pauseCount = 0
    private var polling = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let client: PodpisClient
    /// Called with the holder's name when a card is first read or another card goes in.
    @ObservationIgnored var onHolderChange: ((String) -> Void)?

    init(client: PodpisClient) {
        self.client = client
    }

    func start() {
        guard loop == nil else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        })
        loop = Task { [weak self] in
            await self?.refreshNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if NSApp.isActive { await self.refreshNow() }
            }
        }
    }

    /// Stops polling and waits for a status call still in flight, so the card is free.
    func pauseAndDrain() async {
        pauseCount += 1
        while polling { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func resume() { pauseCount = max(0, pauseCount - 1) }

    func refreshSoon() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        guard pauseCount == 0, !polling else { return }
        polling = true
        defer { polling = false }
        let result: Result<StatusResponse, PodpisError>
        do {
            result = .success(try await client.status())
        } catch let e as PodpisError {
            result = .failure(e)
        } catch {
            result = .failure(.unexpected(exitCode: -1, detail: "\(error)"))
        }
        // A signature may have started while this call ran; its result is stale then.
        guard pauseCount == 0 else { return }
        let next = CardState(result)
        let before = state.info?.name
        if next != state { state = next }
        if let name = next.info?.name, name != before { onHolderChange?(name) }
        lastChecked = Date()
    }
}
