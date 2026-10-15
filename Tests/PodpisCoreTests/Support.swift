import Foundation

enum Paths {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("Tests/Fixtures")
    static let fakeCLI = repo.appendingPathComponent("Tools/fake-podpisz")

    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    /// A fresh scratch folder per test.
    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("podpis-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Environment for the fake CLI: its state folder, a minimal PATH, and HOME and PODPIS_PYTHON
    /// from the test process when set (the fake's Python is found through them).
    static func fakeEnvironment(dir: URL) -> [String: String] {
        var env = ["FAKE_PODPIS_DIR": dir.path, "PATH": "/usr/bin:/bin"]
        for key in ["HOME", "PODPIS_PYTHON"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        return env
    }

    /// Writes an executable shell script and returns its URL.
    static func script(_ body: String, in dir: URL, name: String = "cli") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
