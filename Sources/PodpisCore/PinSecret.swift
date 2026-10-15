import Foundation

/// The card PIN while it is in memory: digits only, zeroed on `wipe()` and on deinit.
///
/// It never becomes a process argument or an environment variable; the CLI gets it on
/// stdin through `stdinLine`.
public final class PinSecret: @unchecked Sendable {
    private var bytes: [UInt8]
    private let lock = NSLock()

    /// 4 to 12 ASCII digits, the format the card and the CLI accept.
    public static func isValid(_ text: String) -> Bool {
        (4...12).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public init?(_ text: String) {
        guard Self.isValid(text) else { return nil }
        bytes = Array(text.utf8)
    }

    public init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8), Self.isValid(text) else { return nil }
        bytes = Array(data)
    }

    /// The PIN followed by a newline, as `--pin-stdin` reads it.
    var stdinLine: Data {
        lock.withLock { Data(bytes + [0x0A]) }
    }

    /// The raw digits, for storing in the Keychain.
    public var data: Data {
        lock.withLock { Data(bytes) }
    }

    public func wipe() {
        lock.withLock {
            for i in bytes.indices { bytes[i] = 0 }
            bytes.removeAll()
        }
    }

    deinit { wipe() }
}
