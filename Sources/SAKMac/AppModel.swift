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

enum UpdateCheckStatus: String, Codable {
    case missing, outdated, current, no_update_listed

    var label: String {
        switch self {
        case .missing: "缺少更新"
        case .outdated: "有新版本"
        case .current: "已是最新"
        case .no_update_listed: "库中无更新记录"
        }
    }
}

struct UpdateCheckResult: Identifiable, Hashable {
    var id: String { baseId }
    var status: UpdateCheckStatus
    var name: String
    var baseId: String
    var updateId: String
    var localVersion: Int?
    var latestVersion: Int?
    var suggestedName: String
    var files: [String]
}

struct UpdateCheckSummary {
    var games = 0
    var missing = 0
    var outdated = 0
    var current = 0
    var unknown = 0
    var errors = 0
    var files = 0
}

/// Shown before convert/merge when updates are missing/outdated, or when the check itself failed.
struct UpdateConfirmPrompt: Identifiable {
    let id = UUID()
    let jobTitle: String
    /// Missing / outdated entries (may be empty if only the check failed).
    let issues: [UpdateCheckResult]
    /// Non-nil when titledb/local parse failed; user can still choose to continue.
    let checkFailedMessage: String?
    let continueAction: () -> Void

    var copyableNames: [String] {
        issues.map(\.suggestedName).filter { !$0.isEmpty }
    }
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
    /// True while a pre-job update check is in progress (before the real convert/merge starts).
    var isPreflightChecking = false
    var statusText = "就绪"
    var progress: Double?
    var progressDetail = ""
    var log: [LogLine] = []

    var toNspFiles: [URL] = []
    var convertFiles: [URL] = []
    var compressFiles: [URL] = []
    var mergeFiles: [URL] = []
    var updateCheckFiles: [URL] = []
    var updateCheckResults: [UpdateCheckResult] = []
    var updateCheckSummary: UpdateCheckSummary?
    var updateConfirm: UpdateConfirmPrompt?

    private var task: Task<Void, Never>?
    private var sawError = false

    var isBusy: Bool { isRunning || isPreflightChecking }

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
        runWithUpdatePreflight(files: files, jobTitle: "转换为 \(target.label)") { [weak self] in
            self?.startConvert(files: files, to: target)
        }
    }

    /// One-shot: any mix of XCI/NSP/NSZ/XCZ → NSP.
    /// Single file uses convert; multiple files (base + update + DLC) are merged into one NSP.
    func toNsp(files: [URL]) {
        runWithUpdatePreflight(files: files, jobTitle: "万物转 NSP") { [weak self] in
            self?.startToNsp(files: files)
        }
    }

    func merge(files: [URL], to target: MergeTarget) {
        runWithUpdatePreflight(files: files, jobTitle: "合并为 \(target.label)") { [weak self] in
            self?.startMerge(files: files, to: target)
        }
    }

    private func startConvert(files: [URL], to target: ConvertTarget) {
        start("转换为 \(target.label)") { model in
            let out = try model.prepareSquirrel()
            for (i, file) in files.enumerated() {
                model.setStatus("转换 (\(i + 1)/\(files.count))：\(file.lastPathComponent)")
                try await model.squirrel(["-o", out.path, "-t", target.rawValue, "-dc", file.path])
            }
        }
    }

    private func startToNsp(files: [URL]) {
        start("万物转 NSP") { model in
            let out = try model.prepareSquirrel()
            if files.count == 1, let file = files.first {
                model.setStatus("转换为 NSP：\(file.lastPathComponent)")
                try await model.squirrel(["-o", out.path, "-t", "nsp", "-dc", file.path])
            } else {
                let list = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sak-tonsp-\(UUID().uuidString).txt")
                try files.map(\.path).joined(separator: "\n").appending("\n")
                    .write(to: list, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: list) }
                model.setStatus("合并 \(files.count) 个文件为 NSP…")
                try await model.squirrel([
                    "-t", "cnsp", "-o", out.path, "-tfile", list.path, "-dmul", "calculate",
                ])
            }
        }
    }

    private func startMerge(files: [URL], to target: MergeTarget) {
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

    /// Check updates before a job; prompt if missing/outdated (or if the check fails).
    func runWithUpdatePreflight(files: [URL], jobTitle: String, action: @escaping () -> Void) {
        guard !isBusy else { return }
        isPreflightChecking = true
        sawError = false
        progress = nil
        progressDetail = ""
        statusText = "运行前检测更新…"
        append("── 运行前检测更新（\(jobTitle)）──", .command)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let issues = try await self.gatherUpdateIssues(files: files, recursive: false)
                try Task.checkCancellation()
                self.isPreflightChecking = false
                self.task = nil
                self.progress = nil
                self.progressDetail = ""
                if issues.isEmpty {
                    self.append("更新检测通过，开始任务", .success)
                    action()
                } else {
                    self.statusText = "发现 \(issues.count) 项更新问题，等待确认是否继续"
                    self.updateConfirm = UpdateConfirmPrompt(
                        jobTitle: jobTitle,
                        issues: issues,
                        checkFailedMessage: nil,
                        continueAction: action
                    )
                }
            } catch is CancellationError {
                self.isPreflightChecking = false
                self.task = nil
                self.progress = nil
                self.progressDetail = ""
                self.statusText = "已取消"
                self.append("已取消更新检测", .error)
            } catch {
                self.isPreflightChecking = false
                self.task = nil
                self.progress = nil
                self.progressDetail = ""
                self.append("更新检测失败：\(error.localizedDescription)", .error)
                self.statusText = "更新检测失败，等待确认是否继续"
                self.updateConfirm = UpdateConfirmPrompt(
                    jobTitle: jobTitle,
                    issues: [],
                    checkFailedMessage: error.localizedDescription,
                    continueAction: action
                )
            }
        }
    }

    func confirmUpdateAndContinue() {
        guard let prompt = updateConfirm else { return }
        updateConfirm = nil
        append("用户确认继续：\(prompt.jobTitle)", .info)
        prompt.continueAction()
    }

    func cancelUpdateConfirm() {
        updateConfirm = nil
        statusText = "已取消"
        append("用户取消，未开始任务", .error)
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

    func checkUpdates(files: [URL], recursive: Bool = true) {
        start("检测更新") { model in
            _ = try await model.gatherUpdateIssues(files: files, recursive: recursive)
        }
    }

    /// Runs titledb check; updates `updateCheckResults` / summary; returns missing+outdated items.
    @discardableResult
    private func gatherUpdateIssues(files: [URL], recursive: Bool) async throws -> [UpdateCheckResult] {
        _ = try prepareSquirrel()
        guard FileManager.default.fileExists(atPath: BackendPaths.checkUpdatesScript.path) else {
            throw PreflightError(message: "找不到 check_updates.py，请重新构建应用")
        }
        updateCheckResults = []
        updateCheckSummary = nil

        let list = FileManager.default.temporaryDirectory
            .appendingPathComponent("sak-check-\(UUID().uuidString).txt")
        try files.map(\.path).joined(separator: "\n").appending("\n")
            .write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }

        setStatus("对照 titledb 检查 \(files.count) 项…")
        var args = [
            BackendPaths.checkUpdatesScript.path,
            "--ztools", BackendPaths.ztools.path,
            "-tfile", list.path,
        ]
        if recursive { args.append("--recursive") }
        append("$ check_updates.py " + args.dropFirst().joined(separator: " "), .command)
        try await ProcessRunner.run(BackendPaths.python, args, cwd: BackendPaths.ztools) {
            [weak self] line in Task { @MainActor in self?.handleUpdateCheckOutput(line) }
        }
        try Task.checkCancellation()
        if sawError, updateCheckResults.isEmpty {
            throw PreflightError(message: "更新检测未得到有效结果，请查看日志")
        }
        return updateCheckResults.filter { $0.status == .missing || $0.status == .outdated }
    }

    func cancel() {
        task?.cancel()
    }

    func revealOutput() {
        NSWorkspace.shared.open(URL(fileURLWithPath: outputDir, isDirectory: true))
    }

    // MARK: - Plumbing

    private func start(_ title: String, _ work: @escaping @MainActor (AppModel) async throws -> Void) {
        guard !isBusy else { return }
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

    private static func jsonInt(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static let tqdmPercent = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%\|"#)

    private func handleUpdateCheckOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            handleOutput(line)
            return
        }

        switch type {
        case "status":
            if let message = json["message"] as? String {
                statusText = message
                append(message, .info)
            }
        case "progress":
            if let percent = Self.jsonDouble(json["percent"]) { progress = percent / 100 }
            let step = json["step"] as? String ?? ""
            let file = (json["file"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            progressDetail = [step, file].filter { !$0.isEmpty }.joined(separator: " · ")
        case "result":
            guard let statusRaw = json["status"] as? String,
                  let status = UpdateCheckStatus(rawValue: statusRaw),
                  let name = json["name"] as? String,
                  let baseId = json["baseId"] as? String,
                  let updateId = json["updateId"] as? String
            else { return }
            let suggested = json["suggestedName"] as? String ?? ""
            let result = UpdateCheckResult(
                status: status,
                name: name,
                baseId: baseId,
                updateId: updateId,
                localVersion: Self.jsonInt(json["localVersion"]),
                latestVersion: Self.jsonInt(json["latestVersion"]),
                suggestedName: suggested,
                files: json["files"] as? [String] ?? []
            )
            if let idx = updateCheckResults.firstIndex(where: { $0.baseId == baseId }) {
                updateCheckResults[idx] = result
            } else {
                updateCheckResults.append(result)
            }
            let verLocal = result.localVersion.map { "v\($0)" } ?? "无"
            let verLatest = result.latestVersion.map { "v\($0)" } ?? "—"
            append("\(result.status.label)：\(name)  本地 \(verLocal) → 最新 \(verLatest)", .info)
            if !suggested.isEmpty, status == .missing || status == .outdated {
                append("  更新包名称：\(suggested)", .command)
            }
        case "summary":
            let summary = UpdateCheckSummary(
                games: Self.jsonInt(json["games"]) ?? 0,
                missing: Self.jsonInt(json["missing"]) ?? 0,
                outdated: Self.jsonInt(json["outdated"]) ?? 0,
                current: Self.jsonInt(json["current"]) ?? 0,
                unknown: Self.jsonInt(json["unknown"]) ?? 0,
                errors: Self.jsonInt(json["errors"]) ?? 0,
                files: Self.jsonInt(json["files"]) ?? 0
            )
            updateCheckSummary = summary
            append(
                "汇总：\(summary.games) 款游戏，缺少 \(summary.missing)，可升级 \(summary.outdated)，已最新 \(summary.current)",
                .success
            )
        case "file_error":
            sawError = true
            let file = (json["file"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            let message = json["message"] as? String ?? "未知错误"
            append("解析失败 \(file)：\(message)", .error)
        case "error":
            sawError = true
            append(json["message"] as? String ?? "检测失败", .error)
        default:
            break
        }
    }

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
