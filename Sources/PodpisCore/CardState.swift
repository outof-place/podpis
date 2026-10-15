import Foundation

/// The reader, the card and its certificate, as the last `podpisz status` saw them.
public enum CardState: Equatable, Sendable {
    case checking
    case ready(CardInfo)
    case noReader
    case noCard
    case pinLocked
    case problem(PodpisError)

    public init(_ result: Result<StatusResponse, PodpisError>, now: Date = Date()) {
        switch result {
        case .success(let s):
            self = .ready(CardInfo(s, now: now))
        case .failure(.cli("brak_czytnika", _)):
            self = .noReader
        case .failure(.cli("brak_karty", _)):
            self = .noCard
        case .failure(.cli("pin_zablokowany", _)):
            self = .pinLocked
        case .failure(let e):
            self = .problem(e)
        }
    }

    public var info: CardInfo? {
        if case .ready(let i) = self { return i }
        return nil
    }

    /// Why signing cannot start right now, or nil when the card is ready.
    public var blocker: String? {
        switch self {
        case .checking: return "Sprawdzam czytnik i kartę…"
        case .noReader: return "Podłącz czytnik kart."
        case .noCard: return "Włóż kartę do czytnika."
        case .pinLocked: return "PIN karty jest zablokowany. Odblokuj go kodem PUK."
        case .problem(let e): return e.advice.title
        case .ready(let i):
            if i.isExpired { return "Certyfikat wygasł \(i.validUntilText). Podpis byłby nieważny." }
            return nil
        }
    }
}

public struct CardInfo: Equatable, Sendable {
    public let name: String
    public let title: String?
    public let pesel: String?
    public let issuer: String?
    public let validUntil: Date?
    public let qualified: Bool
    public let cardNumber: String?
    public let pin: PinFlags
    public let daysLeft: Int?

    public init(_ s: StatusResponse, now: Date = Date()) {
        name = s.certificate.name ?? "Nieznany posiadacz"
        title = s.certificate.title
        pesel = s.certificate.pesel
        issuer = s.certificate.issuer
        qualified = s.certificate.qualified ?? false
        cardNumber = s.cardNumber
        pin = s.pin
        validUntil = s.certificate.validUntil.flatMap(Self.parseDay)
        if let v = validUntil {
            let cal = Calendar(identifier: .gregorian)
            daysLeft = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: v).day
        } else {
            daysLeft = nil
        }
    }

    /// The certificate is valid through the whole `wazny_do` day.
    public var isExpired: Bool { (daysLeft ?? 0) < 0 }
    public var expiresSoon: Bool { !isExpired && (daysLeft ?? Int.max) <= 30 }

    public var validUntilText: String {
        guard let v = validUntil else { return "nieznana data" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "pl_PL")
        f.dateFormat = "d.MM.yyyy"
        return f.string(from: v)
    }

    /// PESEL with all but the last four digits hidden, for screens that may be shared.
    public var maskedPesel: String? {
        guard let p = pesel, p.count > 4 else { return pesel }
        return String(repeating: "•", count: p.count - 4) + p.suffix(4)
    }

    static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
