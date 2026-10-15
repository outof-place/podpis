import Foundation

/// Everything that can go wrong when talking to the podpisz CLI.
public enum PodpisError: Error, Equatable, Sendable {
    /// A known error the CLI reported: exit 2 with {"ok":false,"kod":...,"blad":...}.
    case cli(code: String, message: String)
    /// The CLI crashed or printed something that is not its JSON (exit 3 or worse).
    case unexpected(exitCode: Int32, detail: String)
    case cliMissing(path: String)
    case timedOut(seconds: Int)
    case cancelled

    public var code: String? {
        if case .cli(let code, _) = self { return code }
        return nil
    }

    /// Errors about the card or the PIN: the whole batch stops, nothing is retried.
    public var stopsBatch: Bool {
        switch self {
        case .cli(let code, _):
            return Self.cardCodes.contains(code)
        case .cliMissing, .cancelled:
            return true
        case .unexpected, .timedOut:
            return false
        }
    }

    /// Known errors the CLI raises only after the card accepted the PIN for this file.
    public var isAfterLogin: Bool {
        guard case .cli(let code, _) = self else { return false }
        return ["pieczec", "brak_miejsca", "out_paczka"].contains(code)
    }

    static let cardCodes: Set<String> = [
        "zly_pin", "pin_zablokowany", "ostatnia_proba", "zly_format_pin", "anulowano",
        "brak_czytnika", "brak_karty", "brak_sterownika", "certyfikat",
    ]
}

/// What to tell the user about an error: a short title, the cause and the next step.
public struct Advice: Equatable, Sendable {
    public enum Tone: Sendable { case warning, failure }

    public let title: String
    public let message: String
    public let nextStep: String?
    public let symbol: String
    public let tone: Tone
    /// Raw detail for the "Szczegóły" disclosure, when it adds something.
    public let detail: String?

    public init(title: String, message: String, nextStep: String?, symbol: String, tone: Tone, detail: String?) {
        self.title = title
        self.message = message
        self.nextStep = nextStep
        self.symbol = symbol
        self.tone = tone
        self.detail = detail
    }
}

public extension PodpisError {
    var advice: Advice {
        switch self {
        case .cli(let code, let message):
            return Self.advice(code: code, message: message)
        case .unexpected(let exit, let detail):
            return Advice(
                title: "Coś poszło nie tak",
                message: "Program podpisz zakończył się błędem (kod \(exit)). Plik nie został podpisany.",
                nextStep: "Spróbuj jeszcze raz. Jeśli błąd wraca, skopiuj szczegóły.",
                symbol: "exclamationmark.triangle.fill", tone: .failure, detail: detail)
        case .cliMissing(let path):
            return Advice(
                title: "Nie znalazłem programu podpisz",
                message: "Podpis korzysta z programu \(path), a tego pliku nie ma albo nie da się go uruchomić.",
                nextStep: "Sprawdź instalację podpisz albo ustaw zmienną PODPIS_CLI.",
                symbol: "questionmark.folder.fill", tone: .failure, detail: nil)
        case .timedOut(let seconds):
            return Advice(
                title: "Karta nie odpowiada",
                message: "Po \(seconds) s nie było odpowiedzi, więc przerwałem.",
                nextStep: "Wyjmij i włóż kartę albo podłącz czytnik ponownie, potem spróbuj jeszcze raz.",
                symbol: "hourglass", tone: .failure, detail: nil)
        case .cancelled:
            return Advice(title: "Przerwano", message: "Podpisywanie zostało przerwane.", nextStep: nil,
                          symbol: "stop.circle", tone: .warning, detail: nil)
        }
    }

    private static func advice(code: String, message: String) -> Advice {
        switch code {
        case "zly_pin":
            return Advice(
                title: "Zły PIN",
                message: "Karta odrzuciła PIN i odjęła jedną próbę. Niczego nie ponawiałem.",
                nextStep: "Sprawdź PIN i spróbuj jeszcze raz, powoli.",
                symbol: "lock.trianglebadge.exclamationmark.fill", tone: .failure, detail: nil)
        case "pin_zablokowany":
            return Advice(
                title: "PIN zablokowany",
                message: "Karta zablokowała PIN po zbyt wielu błędnych próbach.",
                nextStep: "Odblokuj PIN kodem PUK, potem wróć tutaj.",
                symbol: "lock.slash.fill", tone: .failure, detail: message)
        case "ostatnia_proba":
            return Advice(
                title: "Ostatnia próba PIN-u",
                message: "Karta ma już tylko jedną próbę. Błędny PIN ją zablokuje.",
                nextStep: "Wpisz PIN ręcznie i potwierdź, że jest pewny.",
                symbol: "exclamationmark.lock.fill", tone: .warning, detail: nil)
        case "zly_format_pin":
            return Advice(title: "PIN w złym formacie", message: "PIN ma od 4 do 12 cyfr.",
                          nextStep: "Wpisz same cyfry.", symbol: "number", tone: .warning, detail: nil)
        case "brak_czytnika":
            return Advice(title: "Nie widzę czytnika", message: "Czytnik kart nie jest podłączony.",
                          nextStep: "Podłącz czytnik USB. Status zmieni się sam.",
                          symbol: "cable.connector.slash", tone: .warning, detail: nil)
        case "brak_karty":
            return Advice(title: "Nie widzę karty", message: "Czytnik jest, ale nie ma w nim karty kwalifikowanej.",
                          nextStep: "Włóż kartę do czytnika. Status zmieni się sam.",
                          symbol: "creditcard.trianglebadge.exclamationmark", tone: .warning, detail: nil)
        case "brak_sterownika":
            return Advice(title: "Brak sterownika karty", message: message,
                          nextStep: "Zainstaluj Szafir2 od KIR (sterownik jest w jego paczce) albo ustaw PODPIS_PKCS11.",
                          symbol: "puzzlepiece.extension", tone: .failure, detail: nil)
        case "certyfikat":
            return Advice(title: "Problem z certyfikatem na karcie", message: message,
                          nextStep: "Sprawdź kartę w aplikacji KIR.", symbol: "person.badge.key.fill",
                          tone: .failure, detail: nil)
        case "brak_kotwicy":
            return Advice(title: "Nie znalazłem tekstu", message: message,
                          nextStep: "Przeciągnij podpis w miejsce podpisu albo wpisz inny tekst.",
                          symbol: "text.magnifyingglass", tone: .warning, detail: nil)
        case "brak_miejsca":
            return Advice(title: "Mało miejsca na podpis", message: message,
                          nextStep: "Przeciągnij podpis tam, gdzie ma się znaleźć.",
                          symbol: "rectangle.compress.vertical", tone: .warning, detail: nil)
        case "pieczec":
            return Advice(title: "Nie udało się narysować podpisu",
                          message: "Grafikę podpisu rysuje Google Chrome w tle i tym razem się nie udało.",
                          nextStep: "Sprawdź, czy Chrome jest zainstalowany, i spróbuj jeszcze raz.",
                          symbol: "paintbrush.pointed.fill", tone: .failure, detail: message)
        case "juz_podpisany":
            return Advice(title: "Plik ma już podpis", message: message,
                          nextStep: "Włącz „Dołóż kolejny podpis”, jeśli to zamierzone.",
                          symbol: "signature", tone: .warning, detail: nil)
        case "anulowano":
            return Advice(title: "Anulowano", message: message, nextStep: nil, symbol: "xmark.circle",
                          tone: .warning, detail: nil)
        case "wyjatek":
            return Advice(title: "Błąd podczas podpisywania", message: "Plik nie został podpisany.",
                          nextStep: "Spróbuj jeszcze raz. Jeśli błąd wraca, skopiuj szczegóły.",
                          symbol: "exclamationmark.triangle.fill", tone: .failure, detail: message)
        default:
            return Advice(title: "Nie udało się", message: message, nextStep: nil,
                          symbol: "exclamationmark.triangle.fill", tone: .failure, detail: "kod: \(code)")
        }
    }
}
