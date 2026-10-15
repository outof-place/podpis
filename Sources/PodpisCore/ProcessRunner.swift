import Foundation

/// What a finished child process left behind.
public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
}

/// Runs one child process with optional stdin bytes, a timeout and task cancellation.
///
/// Stdin is written once and closed, so a secret handed in here never shows up in the
/// argument list or the environment of the child.
enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdin: Data?,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        ignoreSigpipeOnce
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.environment = environment
                    let out = Pipe(), err = Pipe(), inp = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    process.standardInput = inp
                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                    box.set(process)

                    var outData = Data(), errData = Data()
                    let readers = DispatchGroup()
                    readers.enter()
                    DispatchQueue.global().async {
                        outData = out.fileHandleForReading.readDataToEndOfFile()
                        readers.leave()
                    }
                    readers.enter()
                    DispatchQueue.global().async {
                        errData = err.fileHandleForReading.readDataToEndOfFile()
                        readers.leave()
                    }
                    if let stdin {
                        // The child may exit before reading (bad arguments); SIGPIPE is ignored,
                        // so this fails quietly instead of killing the app.
                        try? inp.fileHandleForWriting.write(contentsOf: stdin)
                    }
                    try? inp.fileHandleForWriting.close()

                    let watchdog = DispatchWorkItem { box.terminate(timedOut: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                    process.waitUntilExit()
                    watchdog.cancel()
                    readers.wait()
                    cont.resume(returning: ProcessOutput(
                        exitCode: process.terminationStatus, stdout: outData, stderr: errData,
                        timedOut: box.didTimeOut))
                }
            }
        } onCancel: {
            box.terminate(timedOut: false)
        }
    }

    private static let ignoreSigpipeOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

/// Lets the cancellation handler and the watchdog reach the running process.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    var didTimeOut: Bool { lock.withLock { timedOut } }

    func set(_ p: Process) {
        let kill = lock.withLock { () -> Bool in
            process = p
            return cancelled
        }
        if kill { p.terminate() }
    }

    func terminate(timedOut: Bool) {
        let p = lock.withLock { () -> Process? in
            cancelled = true
            if timedOut { self.timedOut = true }
            return process
        }
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
}
