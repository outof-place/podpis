import Foundation
import LocalAuthentication
import Observation
import PodpisCore
import Security

/// "Zapamiętaj PIN z Touch ID": the PIN sits in the login keychain and the app hands it to
/// the CLI only after a successful Touch ID check.
///
/// The keychain item is readable only by this build of the app (an ad-hoc signed app
/// cannot use the biometry-bound data protection keychain, that needs a provisioning
/// profile), so the Touch ID gate is enforced here. The fingerprint set is recorded with
/// the PIN; when fingers are added or removed, the PIN is forgotten.
@MainActor @Observable
final class PinVault {
    enum Failure: Error, Equatable {
        /// The user closed the Touch ID prompt: do nothing.
        case cancelled
        /// Type the PIN instead, with an optional reason to show.
        case typePIN(String?)
    }

    private(set) var hasPIN = false

    private let service: String
    private let account = "pin-karty-kwalifikowanej"

    /// A PIN remembered while the app talks to a fake CLI (PODPIS_CLI) lives under its own
    /// name, so a test PIN can never reach the real card.
    init(realCard: Bool) {
        service = realCard ? "pl.outofplace.podpis" : "pl.outofplace.podpis.test"
        hasPIN = itemAttributes() != nil
    }

    /// Touch ID can be used right now (it is not when the lid is closed).
    var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func save(_ pin: PinSecret) {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        let fingerprints = ctx.domainState.biometry.stateHash ?? Data()
        deleteItem()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Podpis: PIN karty kwalifikowanej",
            kSecAttrDescription as String: "Używany przez Podpis.app po potwierdzeniu Touch ID",
            kSecAttrGeneric as String: fingerprints,
            kSecValueData as String: pin.data,
        ]
        hasPIN = SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    func forget() {
        deleteItem()
        hasPIN = false
    }

    /// Asks for Touch ID, then returns the stored PIN.
    func unlock(reason: String) async throws -> PinSecret {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Wpisz PIN"
        ctx.localizedCancelTitle = "Anuluj"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw Failure.typePIN("Touch ID jest teraz niedostępny, wpisz PIN.")
        }
        guard let stored = itemAttributes() else {
            hasPIN = false
            throw Failure.typePIN(nil)
        }
        let recorded = stored[kSecAttrGeneric as String] as? Data ?? Data()
        if let now = ctx.domainState.biometry.stateHash, now != recorded {
            forget()
            throw Failure.typePIN("Zmieniły się odciski palców w Touch ID, więc zapomniałem PIN. Wpisz go jeszcze raz.")
        }
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel:
                throw Failure.cancelled
            case .userFallback:
                throw Failure.typePIN(nil)
            case .biometryLockout:
                throw Failure.typePIN("Touch ID jest zablokowany po nieudanych próbach. Wpisz PIN.")
            default:
                throw Failure.typePIN("Touch ID nie zadziałał. Wpisz PIN.")
            }
        }
        guard let data = readSecret(), let pin = PinSecret(data: data) else {
            forget()
            throw Failure.typePIN("Nie udało się odczytać zapamiętanego PIN-u. Wpisz go.")
        }
        return pin
    }

    // MARK: keychain

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func itemAttributes() -> [String: Any]? {
        var q = baseQuery
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? [String: Any]
    }

    private func readSecret() -> Data? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func deleteItem() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
