import Foundation
import Security

public enum DocumentKind: String, Sendable {
    case pdf, xml
}

/// Cheap checks on a dropped file, before anything is sent to the CLI.
public enum DocumentInspector {
    /// PDF or XML by content, so a mislabelled extension does not get through.
    public static func kind(of url: URL) -> DocumentKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        if head.starts(with: Data("%PDF-".utf8)) || (head.range(of: Data("%PDF-".utf8)).map { $0.lowerBound < 1024 } ?? false) {
            return .pdf
        }
        var text = String(decoding: head, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.drop { $0.isWhitespace }
        if trimmed.hasPrefix("<?xml") || (url.pathExtension.lowercased() == "xml" && trimmed.hasPrefix("<")) {
            return .xml
        }
        return nil
    }

    /// A PDF signature always carries a /ByteRange; a plain document never does.
    public static func pdfHasSignature(_ data: Data) -> Bool {
        data.range(of: Data("/ByteRange".utf8)) != nil
    }

    /// Signers of an XML-DSig signed file, read from the certificates inside the signatures.
    /// Returns nil when the file has no signature at all.
    public static func xmlSigners(_ text: String) -> [String]? {
        let dsig = "http://www.w3.org/2000/09/xmldsig#"
        guard text.contains(dsig),
              text.range(of: #"<([A-Za-z_][\w.-]*:)?Signature[\s>]"#, options: .regularExpression) != nil
        else { return nil }
        let pattern = #"<(?:[A-Za-z_][\w.-]*:)?X509Certificate>([A-Za-z0-9+/=\s]+)</"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var names: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let b64 = text[r].filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(b64)),
                  let cert = SecCertificateCreateWithData(nil, der as CFData),
                  let summary = SecCertificateCopySubjectSummary(cert) as String?
            else { continue }
            if !names.contains(summary) { names.append(summary) }
        }
        return names
    }

    /// Whether `holder` (the name on the card) is among `signers`.
    public static func signedBy(_ holder: String, in signers: [String]) -> Bool {
        let h = holder.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !h.isEmpty else { return false }
        return signers.contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(h)
        }
    }
}
