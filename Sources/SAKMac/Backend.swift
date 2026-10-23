import Foundation

enum BackendPaths {
    static let support: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SAKMac", isDirectory: true)

    static var resources: URL {
        if let override = ProcessInfo.processInfo.environment["SAK_RESOURCES"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL!
    }

    static var bundledBackend: URL { resources.appendingPathComponent("backend", isDirectory: true) }
    static var setupScript: URL { resources.appendingPathComponent("setup_backend.sh") }

    static var python: URL { support.appendingPathComponent("venv/bin/python") }
    static var nsz: URL { support.appendingPathComponent("venv/bin/nsz") }
    static var ztools: URL { support.appendingPathComponent("NSC_BUILDER/ztools", isDirectory: true) }
    static var squirrel: URL { ztools.appendingPathComponent("squirrel.py") }
    static var nscbKeys: URL { ztools.appendingPathComponent("keys.txt") }
    static var installedVersion: URL { support.appendingPathComponent(".backend_version") }
    static var bundledVersion: URL { bundledBackend.appendingPathComponent("VERSION") }

    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: python.path),
              fm.fileExists(atPath: squirrel.path),
              let installed = try? String(contentsOf: installedVersion, encoding: .utf8)
        else { return false }
        let bundled = (try? String(contentsOf: bundledVersion, encoding: .utf8)) ?? installed
        return installed.trimmingCharacters(in: .whitespacesAndNewlines)
            == bundled.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ProcessFailure: LocalizedError {
    let status: Int32
    var errorDescription: String? { "进程退出码 \(status)" }
}

enum ProcessRunner {
    /// Runs a process, streaming stdout and stderr line by line (splitting on `\n` and `\r`
    /// so tqdm-style progress bars arrive as separate updates).
    static func run(
        _ executable: URL,
        _ arguments: [String],
        cwd: URL? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let splitter = LineSplitter(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                splitter.feed(data)
            }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                process.terminationHandler = { p in
                    cont.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { splitter.feed(rest) }
        splitter.flush()

        try Task.checkCancellation()
        if status != 0 { throw ProcessFailure(status: status) }
    }
}

private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .isoLatin1),
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(s)
            }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if let s = String(data: rest, encoding: .utf8), !s.trimmingCharacters(in: .whitespaces).isEmpty {
            onLine(s)
        }
    }
}
