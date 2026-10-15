import CoreGraphics
import Foundation

// JSON shapes printed by `podpisz ... --json`. Field names stay Polish to match the CLI.

public struct PinFlags: Decodable, Equatable, Sendable {
    public let lastTry: Bool
    public let lowTries: Bool

    public init(lastTry: Bool, lowTries: Bool) {
        self.lastTry = lastTry
        self.lowTries = lowTries
    }

    enum CodingKeys: String, CodingKey {
        case lastTry = "ostatnia_proba"
        case lowTries = "malo_prob"
    }
}

public struct CertificateInfo: Decodable, Equatable, Sendable {
    public let name: String?
    public let title: String?
    public let pesel: String?
    public let issuer: String?
    public let validUntil: String?
    public let qualified: Bool?

    enum CodingKeys: String, CodingKey {
        case name = "imie_nazwisko"
        case title = "tytul"
        case pesel
        case issuer = "wystawca"
        case validUntil = "wazny_do"
        case qualified = "kwalifikowany"
    }
}

public struct StatusResponse: Decodable, Equatable, Sendable {
    public let token: String?
    public let cardNumber: String?
    public let pin: PinFlags
    public let certificate: CertificateInfo

    enum CodingKeys: String, CodingKey {
        case token
        case cardNumber = "numer_karty"
        case pin
        case certificate = "certyfikat"
    }
}

/// `miejsce`: the page (1-based) and the rect as poppler sees the page (see PageGeometry).
public struct PlacementResponse: Decodable, Equatable, Sendable {
    public let page: Int
    public let rect: [Double]

    enum CodingKeys: String, CodingKey {
        case page = "strona"
        case rect
    }

    public var cgRect: CGRect? {
        guard rect.count == 4 else { return nil }
        return CGRect(x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1])
    }
}

/// `grafika`: a transparent PNG of the exact signature art.
public struct ArtResponse: Decodable, Equatable, Sendable {
    public let file: String
    public let width: Double
    public let height: Double

    enum CodingKeys: String, CodingKey {
        case file = "plik"
        case width = "szer"
        case height = "wys"
    }
}

public struct XMLCheck: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let xmlsec1: [String]?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, xmlsec1
        case error = "blad"
    }
}

/// One signed file, from `pdf` (one entry of `pliki`) or from `xml`.
public struct SignedFile: Decodable, Equatable, Sendable {
    public let path: String
    public let page: Int?
    public let originalIsPrefix: Bool?
    public let signer: String?
    public let sha256: String?
    public let xmlCheck: XMLCheck?

    public var url: URL { URL(fileURLWithPath: path) }

    enum CodingKeys: String, CodingKey {
        case path = "plik"
        case page = "strona"
        case originalIsPrefix = "oryginal_jest_prefiksem"
        case signer = "podpisal"
        case sha256
        case xmlCheck = "weryfikacja"
    }
}

struct PDFSignResponse: Decodable {
    let files: [SignedFile]
    enum CodingKeys: String, CodingKey { case files = "pliki" }
}

public struct PDFSignatureCheck: Decodable, Equatable, Sendable {
    public let field: String?
    public let signer: String?
    public let time: String?
    public let intact: Bool
    public let coverage: String?
    public let changesAfter: String?

    enum CodingKeys: String, CodingKey {
        case field = "pole"
        case signer = "podpisal"
        case time = "czas"
        case intact = "integralnosc"
        case coverage = "obejmuje"
        case changesAfter = "zmiany_po"
    }
}

/// `sprawdz`: either a list of PDF signatures or the xmlsec1 result.
public struct VerifyResponse: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let signatures: [PDFSignatureCheck]?
    public let xml: XMLCheck?

    enum CodingKeys: String, CodingKey {
        case ok
        case signatures = "podpisy"
        case xml
    }

    /// Names of everyone who signed the PDF, in signing order.
    public var signers: [String] { (signatures ?? []).compactMap(\.signer) }

    /// The newest signature is intact and covers the whole file, so nothing was appended after it.
    public var newestCoversWholeFile: Bool {
        if let xml { return xml.ok }
        guard let last = signatures?.last else { return false }
        return last.intact && last.coverage == "ENTIRE_FILE"
    }
}

struct Envelope: Decodable {
    let ok: Bool?
    let kod: String?
    let blad: String?
}
