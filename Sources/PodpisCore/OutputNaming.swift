import Foundation

/// Picks where a signed copy goes: next to the original as "<name>-podpisany.<ext>",
/// never over an existing file and never over another file of the same batch.
public enum OutputNaming {
    public static let suffix = "-podpisany"

    public struct Plan: Equatable, Sendable {
        public let url: URL
        /// The original folder is read-only, so the copy goes to the fallback folder.
        public let movedToFallback: Bool
        /// A file with the plain "-podpisany" name already exists (maybe signed earlier).
        public let plainNameTaken: Bool
    }

    public static func plan(
        for input: URL,
        reserved: Set<String> = [],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isWritableDirectory: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
        fallbackDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    ) -> Plan {
        let ext = input.pathExtension.isEmpty ? "pdf" : input.pathExtension
        let stem = baseStem(of: input.deletingPathExtension().lastPathComponent)
        let original = input.deletingLastPathComponent()
        let writable = isWritableDirectory(original)
        let folder = writable ? original : fallbackDirectory

        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? "\(stem)\(suffix).\(ext)" : "\(stem)\(suffix)-\(n).\(ext)"
            return folder.appendingPathComponent(name)
        }
        func free(_ url: URL) -> Bool {
            !fileExists(url) && !reserved.contains(url.standardizedFileURL.path) && url.standardizedFileURL != input.standardizedFileURL
        }
        let plain = candidate(1)
        var n = 1
        while !free(candidate(n)) { n += 1 }
        return Plan(url: candidate(n), movedToFallback: !writable, plainNameTaken: !free(plain))
    }

    /// "umowa-podpisany-2" -> "umowa", so signing a signed copy again gives "umowa-podpisany-3"
    /// instead of "umowa-podpisany-2-podpisany".
    static func baseStem(of name: String) -> String {
        if let r = name.range(of: #"-podpisany(-\d+)?$"#, options: .regularExpression), r.lowerBound > name.startIndex {
            return String(name[..<r.lowerBound])
        }
        return name
    }
}
