import CoreGraphics
import Foundation

/// Typed front of the `podpisz` CLI. Every call is a fresh process, which is also how
/// hot-plugging the reader works: the card driver is loaded anew each time.
public struct PodpisClient: Sendable {
    public let executable: URL
    let environment: [String: String]

    public init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.environment = Self.childEnvironment(environment)
    }

    public static let defaultExecutable = URL(fileURLWithPath: NSString(string: "~/.local/bin/podpisz").expandingTildeInPath)

    /// `PODPIS_CLI` when set (tests point it at a fake), otherwise ~/.local/bin/podpisz.
    public static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> PodpisClient {
        guard let path = environment["PODPIS_CLI"], !path.isEmpty else {
            return PodpisClient(executable: defaultExecutable, environment: environment)
        }
        return PodpisClient(executable: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath),
                            environment: environment)
    }

    /// Apps started from Finder get a bare PATH; the CLI needs poppler and xmlsec1 from Homebrew.
    static func childEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "PODPIS_PIN")
        let preferred = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let path = (preferred + (base["PATH"] ?? "").split(separator: ":").map(String.init))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = path.joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        if env["LANG"] == nil { env["LANG"] = "pl_PL.UTF-8" }
        return env
    }

    // MARK: commands

    public func status() async throws -> StatusResponse {
        try await call(["status", "--json"], timeout: 20)
    }

    /// Where the CLI would put the signature above `anchor`; the rect is in poppler's view of the page.
    public func place(pdf: URL, anchor: String, page: Int? = nil) async throws -> PlacementResponse {
        var args = ["miejsce", pdf.path, "--nad", anchor]
        if let page { args += ["--strona", String(page)] }
        return try await call(args + ["--json"], timeout: 60)
    }

    /// Renders the exact signature art for a `width` x `height` pt box into `output` (PNG).
    /// `name` is typed in a script font when there is no handwritten signature image.
    public func art(output: URL, name: String, width: Int?, height: Int?) async throws -> ArtResponse {
        var args = ["grafika", "--out", output.path]
        if !name.isEmpty { args += ["--imie", name] }
        if let width { args += ["--szer", String(width)] }
        if let height { args += ["--wys", String(height)] }
        return try await call(args + ["--json"], timeout: 60)
    }

    /// Signs one PDF at an exact spot. `page` is 1-based; `rect` is in PDF user space.
    public func signPDF(_ file: URL, page: Int, rect: CGRect, output: URL,
                        pin: PinSecret, allowLastTry: Bool) async throws -> SignedFile {
        let r = rect.roundedToPoints()
        var args = ["pdf", file.path, "--strona", String(page), "--rect"]
        args += [r.minX, r.minY, r.maxX, r.maxY].map { String(Int($0)) }
        args += ["--out", output.path, "--pin-stdin", "--json"]
        if allowLastTry { args.append("--wymus") }
        let response: PDFSignResponse = try await call(args, stdin: pin.stdinLine, timeout: 240)
        guard let first = response.files.first else {
            throw PodpisError.unexpected(exitCode: 0, detail: "Brak pliku w odpowiedzi programu podpisz.")
        }
        return first
    }

    public func signXML(_ file: URL, output: URL, pin: PinSecret, allowLastTry: Bool,
                        addAnother: Bool) async throws -> SignedFile {
        var args = ["xml", file.path, "--out", output.path, "--pin-stdin", "--json"]
        if addAnother { args.append("--kolejny") }
        if allowLastTry { args.append("--wymus") }
        return try await call(args, stdin: pin.stdinLine, timeout: 240)
    }

    public func verify(_ file: URL) async throws -> VerifyResponse {
        try await call(["sprawdz", file.path, "--json"], timeout: 90)
    }

    // MARK: plumbing

    func call<T: Decodable>(_ args: [String], stdin: Data? = nil, timeout: TimeInterval) async throws -> T {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PodpisError.cliMissing(path: executable.path)
        }
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(executable: executable, arguments: args,
                                                 environment: environment, stdin: stdin, timeout: timeout)
        } catch is CancellationError {
            throw PodpisError.cancelled
        } catch {
            throw PodpisError.cliMissing(path: executable.path)
        }
        debugLog(args, output)
        if Task.isCancelled { throw PodpisError.cancelled }
        if output.timedOut { throw PodpisError.timedOut(seconds: Int(timeout)) }
        return try Self.decode(output)
    }

    /// PODPIS_DEBUG_LOG=path appends each call: the command, its exit code and the CLI's error
    /// code. Nothing the card returns (name, PESEL) goes there, and the PIN, which travels on
    /// stdin, never does.
    private func debugLog(_ args: [String], _ output: ProcessOutput) {
        guard let path = environment["PODPIS_DEBUG_LOG"], !path.isEmpty else { return }
        let stdout = String(decoding: output.stdout, as: UTF8.self)
        let code = stdout.firstMatch(of: #/"kod":\s*"([a-z_]+)"/#).map { String($0.1) } ?? "-"
        let line = "\(Date()) \(args.first ?? "?") exit=\(output.exitCode) kod=\(code)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// The CLI prints one JSON object on stdout. Python warnings may land before it, so the
    /// last line that looks like JSON wins.
    static func decode<T: Decodable>(_ output: ProcessOutput) throws -> T {
        let text = String(decoding: output.stdout, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") }.map(String.init)
        let stderrTail = String(String(decoding: output.stderr, as: UTF8.self).suffix(1500))
        guard let line, let data = line.data(using: .utf8) else {
            throw PodpisError.unexpected(exitCode: output.exitCode,
                                         detail: stderrTail.isEmpty ? text : stderrTail)
        }
        let decoder = JSONDecoder()
        if let env = try? decoder.decode(Envelope.self, from: data), env.ok == false, let kod = env.kod {
            throw PodpisError.cli(code: kod, message: env.blad ?? kod)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PodpisError.unexpected(exitCode: output.exitCode, detail: "\(error)\n\(line)")
        }
    }
}

extension CGRect {
    /// Whole points, the way the CLI rounds them, keeping the size of the box.
    public func roundedToPoints() -> CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}
