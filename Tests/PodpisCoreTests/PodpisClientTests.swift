import CoreGraphics
import Foundation
@testable import PodpisCore
import Testing

/// The contract with the podpisz CLI, run against stub scripts and the fake CLI.
@Suite struct PodpisClientTests {
    /// A PIN in the argument list is visible to every process on the Mac (ps); it must travel
    /// on stdin only, as digits and a newline, with --pin-stdin, and never in the environment.
    @Test func pinTravelsOnStdinOnly() async throws {
        let dir = try Paths.scratch()
        let cli = try Paths.script("""
            printf '%s\\n' "$@" > "\(dir.path)/argv"
            cat > "\(dir.path)/stdin"
            env > "\(dir.path)/env"
            echo '{"ok": true, "pliki": [{"ok": true, "plik": "/tmp/x-podpisany.pdf", "strona": 1, "podpisal": "Jan Kowalski"}]}'
            """, in: dir)
        let client = PodpisClient(executable: cli, environment: ["PATH": "/usr/bin:/bin", "PODPIS_PIN": "0000"])
        let pin = try #require(PinSecret("48151623"))
        let file = try await client.signPDF(URL(fileURLWithPath: "/tmp/x.pdf"), page: 2,
                                            rect: CGRect(x: 339.4, y: 398, width: 140, height: 48),
                                            output: URL(fileURLWithPath: "/tmp/x-podpisany.pdf"),
                                            pin: pin, allowLastTry: false)
        #expect(file.path == "/tmp/x-podpisany.pdf")
        let stdin = try String(contentsOf: dir.appendingPathComponent("stdin"), encoding: .utf8)
        let argv = try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8)
        let env = try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8)
        #expect(stdin == "48151623\n")
        #expect(!argv.contains("48151623"))
        #expect(!env.contains("48151623") && !env.contains("PODPIS_PIN"))
        #expect(argv.split(separator: "\n") == ["pdf", "/tmp/x.pdf", "--strona", "2", "--rect", "339", "398", "479", "446",
                                                "--out", "/tmp/x-podpisany.pdf", "--pin-stdin", "--json"])
    }

    @Test func lastTryIsAllowedOnlyWhenAsked() async throws {
        let dir = try Paths.scratch()
        let cli = try Paths.script("""
            printf '%s\\n' "$@" > "\(dir.path)/argv"; cat > /dev/null
            echo '{"ok": true, "plik": "/tmp/a-podpisany.xml", "podpisal": "Jan Kowalski", "weryfikacja": {"ok": true}}'
            """, in: dir)
        let client = PodpisClient(executable: cli)
        _ = try await client.signXML(URL(fileURLWithPath: "/tmp/a.xml"), output: URL(fileURLWithPath: "/tmp/a-podpisany.xml"),
                                     pin: try #require(PinSecret("1234")), allowLastTry: true, addAnother: false)
        let argv = try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8)
        #expect(argv.contains("--wymus"))
        #expect(!argv.contains("--kolejny"))
    }

    @Test func knownErrorIsDecodedFromExitTwo() async throws {
        let dir = try Paths.scratch()
        let cli = try Paths.script("""
            cat > /dev/null
            echo '{"ok": false, "kod": "zly_pin", "blad": "Zły PIN. Nie próbuję ponownie."}'; exit 2
            """, in: dir)
        await #expect(throws: PodpisError.cli(code: "zly_pin", message: "Zły PIN. Nie próbuję ponownie.")) {
            _ = try await PodpisClient(executable: cli).signXML(
                URL(fileURLWithPath: "/tmp/a.xml"), output: URL(fileURLWithPath: "/tmp/b.xml"),
                pin: PinSecret("1234")!, allowLastTry: false, addAnother: false)
        }
    }

    /// Python warnings may come first on stdout; the JSON line still wins.
    @Test func jsonAfterNoiseIsFound() async throws {
        let dir = try Paths.scratch()
        let cli = try Paths.script("""
            echo 'DeprecationWarning: something'
            echo '{"ok": true, "strona": 3, "rect": [10, 20, 150, 68]}'
            """, in: dir)
        let r = try await PodpisClient(executable: cli).place(pdf: URL(fileURLWithPath: "/tmp/a.pdf"), anchor: "Jan Kowalski")
        #expect(r.page == 3 && r.cgRect == CGRect(x: 10, y: 20, width: 140, height: 48))
    }

    @Test func crashWithoutJSONIsUnexpected() async throws {
        let dir = try Paths.scratch()
        let cli = try Paths.script("echo 'Segmentation fault' >&2; exit 139", in: dir)
        do {
            _ = try await PodpisClient(executable: cli).status()
            Issue.record("expected an error")
        } catch let PodpisError.unexpected(exitCode, detail) {
            #expect(exitCode == 139 && detail.contains("Segmentation fault"))
        }
    }

    @Test func missingCLIIsReportedAsSuch() async {
        let client = PodpisClient(executable: URL(fileURLWithPath: "/nonexistent/podpisz"))
        await #expect(throws: PodpisError.cliMissing(path: "/nonexistent/podpisz")) { _ = try await client.status() }
    }

    @Test func childGetsHomebrewOnPath() {
        let env = PodpisClient.childEnvironment(["PATH": "/usr/bin:/bin"])
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }

    // MARK: against the fake CLI

    private func fake(_ state: [String: Any]) throws -> PodpisClient {
        let dir = try Paths.scratch()
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: dir.appendingPathComponent("state.json"))
        return PodpisClient(executable: Paths.fakeCLI, environment: Paths.fakeEnvironment(dir: dir))
    }

    @Test func statusOfAReadyCard() async throws {
        let s = try await fake(["karta": "ok", "proby": 2]).status()
        let state = CardState(.success(s))
        let info = try #require(state.info)
        #expect(info.name == "Jan Kowalski")
        #expect(info.pin == PinFlags(lastTry: false, lowTries: true))
        #expect(state.blocker == nil)
    }

    @Test(arguments: [("brak_czytnika", CardState.noReader), ("brak_karty", .noCard)])
    func unpluggedReaderAndMissingCard(code: String, expected: CardState) async throws {
        let client = try fake(["karta": code])
        let result: Result<StatusResponse, PodpisError>
        do { result = .success(try await client.status()) } catch let e as PodpisError { result = .failure(e) }
        #expect(CardState(result) == expected)
    }

    @Test func lockedPinIsItsOwnState() async throws {
        let client = try fake(["karta": "ok", "proby": 0])
        let result: Result<StatusResponse, PodpisError>
        do { result = .success(try await client.status()) } catch let e as PodpisError { result = .failure(e) }
        #expect(CardState(result) == .pinLocked)
    }

    @Test func expiredCertificateBlocksSigning() throws {
        let json = #"{"ok": true, "pin": {"ostatnia_proba": false, "malo_prob": false}, "certyfikat": {"imie_nazwisko": "Jan Kowalski", "wazny_do": "2026-10-14", "kwalifikowany": true}}"#
        let s = try JSONDecoder().decode(StatusResponse.self, from: Data(json.utf8))
        let expired = CardState(.success(s), now: CardInfo.parseDay("2026-10-15")!)
        #expect(expired.info?.isExpired == true)
        #expect(expired.blocker?.contains("wygasł") == true)
        // valid through the whole last day
        #expect(CardState(.success(s), now: CardInfo.parseDay("2026-10-14")!).blocker == nil)
    }
}
