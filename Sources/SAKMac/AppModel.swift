import AppKit
import Foundation
import Observation

enum ConvertTarget: String, CaseIterable, Identifiable {
    case nsp, xci
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum MergeTarget: String, CaseIterable, Identifiable {
    case xci, nsp
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    /// NSC_BUILDER builds multi-content NSPs with the "cnsp" type (title rights removed).
    var squirrelType: String { self == .nsp ? "cnsp" : "xci" }
}

struct LogLine: Identifiable {
    enum Kind { case info, command, error, success }
    let id = UUID()
    let text: String
    let kind: Kind
}

struct PreflightError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class AppModel {
    var keysPath: String {
        didSet { UserDefaults.standard.set(keysPath, forKey: "keysPath") }
    }
    var outputDir: String {
        didSet { UserDefaults.standard.set(outputDir, forKey: "outputDir") }
    }

    var backendReady = BackendPaths.isInstalled
    var isRunning = false
    var statusText = "就绪"
    var progress: Double?
    var progressDetail = ""
    var log: [LogLine] = []

    var convertFiles: [URL] = []
    var compressFiles: [URL] = []
    var mergeFiles: [URL] = []

    private var task: Task<Void, Never>?
    private var sawError = false

    init() {
        let defaults = UserDefaults.standard
        let defaultKeys = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".switch/prod.keys").path
        keysPath = defaults.string(forKey: "keysPath") ?? defaultKeys
        outputDir = defaults.string(forKey: "outputDir")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/SAK Output").path
    }

    var keysAvailable: Bool { FileManager.default.fileExists(atPath: keysPath) }

    // MARK: - Jobs

    func installBackend() {
        start("安装后端") { model in
            model.append("后端将安装到 \(BackendPaths.support.path)", .info)
            try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/bash"),
                [BackendPaths.setupScript.path, BackendPaths.bundledBackend.path, BackendPaths.support.path]
            ) { line in Task { @MainActor in model.append(line, .info) } }
            model.backendReady = BackendPaths.isInstalled
        }
    }

    func convert(files: [URL], to target: ConvertTarget) {
        start("转换为 \(target.label)") { model in
            let out = try model.prepareSquirrel()
            for (i, file) in files.enumerated() {
                model.setStatus("转换 (\(i + 1)/\(files.count))：\(file.lastPathComponent)")
                try await model.squirrel(["-o", out.path, "-t", target.rawValue, "-dc", file.path])
            }
        }
    }

    func merge(files: [URL], to target: MergeTarget) {
        start("合并为 \(target.label)") { model in
            let out = try model.prepareSquirrel()
            let list = FileManager.default.temporaryDirectory
                .appendingPathComponent("sak-merge-\(UUID().uuidString).txt")
            try files.map(\.path).joined(separator: "\n").appending("\n")
                .write(to: list, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: list) }
            model.setStatus("合并 \(files.count) 个文件…")
            try await model.squirrel([
                "-t", target.squirrelType, "-o", out.path, "-tfile", list.path, "-dmul", "calculate",
            ])
        }
    }

    func compress(files: [URL], level: Int, verify: Bool) {
        start("压缩为 NSZ/XCZ") { model in
            let out = try model.prepareNsz()
            var args = ["-C", "-l", String(level)]
            if verify { args.append("-V") }
            model.setStatus("压缩 \(files.count) 个文件…")
            try await model.nsz(args + ["--keys", model.keysPath, "-o", out.path] + files.map(\.path))
        }
    }

    func decompress(files: [URL]) {
        start("解压为 NSP/XCI") { model in
            let out = try model.prepareNsz()
            model.setStatus("解压 \(files.count) 个文件…")
            try await model.nsz(["-D", "--keys", model.keysPath, "-o", out.path] + files.map(\.path))
        }
    }

    func cancel() {
        task?.cancel()
    }

    func revealOutput() {
        NSWorkspace.shared.open(URL(fileURLWithPath: outputDir, isDirectory: true))
    }

    // MARK: - Plumbing

    private func start(_ title: String, _ work: @escaping @MainActor (AppModel) async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        sawError = false
        progress = nil
        progressDetail = ""
        statusText = title + "…"
        append("── \(title) ──", .command)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
                if self.sawError {
                    self.finish("\(title)完成，但日志中有错误，请检查", .error)
                } else {
                    self.finish("\(title)完成", .success)
                }
            } catch is CancellationError {
                self.finish("已取消", .error)
            } catch {
                self.finish("\(title)失败：\(error.localizedDescription)", .error)
            }
        }
    }

    private func finish(_ message: String, _ kind: LogLine.Kind) {
        append(message, kind)
        statusText = message
        progress = nil
        progressDetail = ""
        isRunning = false
        task = nil
    }

    private func setStatus(_ text: String) {
        statusText = text
        progress = nil
        progressDetail = ""
    }

    private func append(_ text: String, _ kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    func clearLog() { log.removeAll() }

    private func requireBackendAndKeys() throws -> URL {
        guard BackendPaths.isInstalled else {
            throw PreflightError(message: "后端尚未安装，请到「设置」里点击「安装后端」")
        }
        guard keysAvailable else {
            throw PreflightError(message: "找不到密钥文件 \(keysPath)，请到「设置」里选择你自己的 prod.keys")
        }
        let out = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    private func prepareSquirrel() throws -> URL {
        let out = try requireBackendAndKeys()
        let fm = FileManager.default
        if fm.fileExists(atPath: BackendPaths.nscbKeys.path) {
            try fm.removeItem(at: BackendPaths.nscbKeys)
        }
        try fm.copyItem(at: URL(fileURLWithPath: keysPath), to: BackendPaths.nscbKeys)
        return out
    }

    private func prepareNsz() throws -> URL { try requireBackendAndKeys() }

    private func squirrel(_ args: [String]) async throws {
        append("$ squirrel.py " + args.joined(separator: " "), .command)
        try await ProcessRunner.run(BackendPaths.python, [BackendPaths.squirrel.path] + args, cwd: BackendPaths.ztools) {
            [weak self] line in Task { @MainActor in self?.handleOutput(line) }
        }
    }

    private func nsz(_ args: [String]) async throws {
        append("$ nsz " + args.joined(separator: " "), .command)
        try await ProcessRunner.run(BackendPaths.nsz, ["--machine-readable"] + args) {
            [weak self] line in Task { @MainActor in self?.handleOutput(line) }
        }
    }

    private static let tqdmPercent = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%\|"#)

    private func handleOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            if type == "progress" {
                if let percent = json["percent"] as? Double { progress = percent / 100 }
                let step = json["step"] as? String ?? ""
                let file = (json["file"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                progressDetail = [step, file].filter { !$0.isEmpty }.joined(separator: " · ")
                return
            }
            if type == "complete" {
                progress = 1
                if let file = json["file"] as? String, !file.isEmpty { append("已生成 \(file)", .success) }
                return
            }
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = Self.tqdmPercent.firstMatch(in: trimmed, range: range),
           let r = Range(match.range(at: 1), in: trimmed), let value = Double(trimmed[r]) {
            progress = min(value / 100, 1)
            progressDetail = trimmed
            return
        }

        let lower = trimmed.lowercased()
        let isError = lower.contains("exception") || lower.contains("traceback")
            || lower.hasPrefix("error") || lower.contains("missing from keys")
            || trimmed.hasPrefix("Filename: UNKNOWN")
        if isError { sawError = true }
        append(trimmed, isError ? .error : .info)
    }
}
