import AppKit
import SwiftUI

struct ToNspView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("导入 XCI / NSZ / XCZ / NSP；单个文件直接转成 NSP，多个文件（本体 + 更新 + DLC）合并成一个 NSP。同一内容有多个版本时保留最新。")
                .foregroundStyle(.secondary)
            FileListEditor(
                files: $model.toNspFiles,
                extensions: ["xci", "nsp", "xcz", "nsz"],
                hint: "单文件转换，或多文件合并为 NSP"
            )
            HStack {
                Spacer()
                Button("转为 NSP") { model.toNsp(files: model.toNspFiles) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.toNspFiles.isEmpty)
            }
        }
    }
}

struct ConvertView: View {
    @Environment(AppModel.self) private var model
    @State private var target: ConvertTarget = .nsp

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("把 XCI 转成 NSP，或把 NSP 转成 XCI。也可以直接输入压缩过的 NSZ / XCZ。")
                .foregroundStyle(.secondary)
            FileListEditor(files: $model.convertFiles, extensions: ["xci", "nsp", "xcz", "nsz"])
            HStack {
                Picker("输出格式", selection: $target) {
                    ForEach(ConvertTarget.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                Button("开始转换") { model.convert(files: model.convertFiles, to: target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.convertFiles.isEmpty)
            }
        }
    }
}

struct CompressView: View {
    @Environment(AppModel.self) private var model
    @State private var level = 18
    @State private var verify = true

    private var compressible: [URL] {
        model.compressFiles.filter { ["nsp", "xci"].contains($0.pathExtension.lowercased()) }
    }
    private var decompressible: [URL] {
        model.compressFiles.filter { ["nsz", "xcz"].contains($0.pathExtension.lowercased()) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("NSP → NSZ、XCI → XCZ 压缩；或把 NSZ / XCZ 还原成 NSP / XCI。")
                .foregroundStyle(.secondary)
            FileListEditor(files: $model.compressFiles, extensions: ["nsp", "xci", "nsz", "xcz"])
            HStack {
                Stepper("压缩等级：\(level)", value: $level, in: 1...22)
                    .help("默认 18。越高压缩率越好，但越慢；22 为最大。")
                Toggle("压缩后校验", isOn: $verify)
                Spacer()
                Button("解压 \(decompressible.count) 个") { model.decompress(files: decompressible) }
                    .disabled(model.isBusy || decompressible.isEmpty)
                Button("压缩 \(compressible.count) 个") {
                    model.compress(files: compressible, level: level, verify: verify)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || compressible.isEmpty)
            }
        }
    }
}

struct MergeView: View {
    @Environment(AppModel.self) private var model
    @State private var target: MergeTarget = .nsp

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("把同一个游戏的本体、更新和 DLC 合并成一个文件。同一内容有多个版本时，自动保留最新版本。")
                .foregroundStyle(.secondary)
            FileListEditor(
                files: $model.mergeFiles,
                extensions: ["xci", "nsp", "xcz", "nsz"],
                hint: "一次只放一个游戏的文件"
            )
            HStack {
                Picker("输出格式", selection: $target) {
                    ForEach(MergeTarget.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                Button("开始合并") { model.merge(files: model.mergeFiles, to: target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.mergeFiles.count < 2)
            }
        }
    }
}

struct UpdateCheckView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: UpdateFilter = .needsAttention

    private enum UpdateFilter: String, CaseIterable, Identifiable {
        case needsAttention, all, missing, outdated, current
        var id: String { rawValue }
        var label: String {
            switch self {
            case .needsAttention: "需处理"
            case .all: "全部"
            case .missing: "缺少"
            case .outdated: "可升级"
            case .current: "已最新"
            }
        }
    }

    private var filtered: [UpdateCheckResult] {
        switch filter {
        case .all: model.updateCheckResults
        case .needsAttention:
            model.updateCheckResults.filter { $0.status == .missing || $0.status == .outdated }
        case .missing:
            model.updateCheckResults.filter { $0.status == .missing }
        case .outdated:
            model.updateCheckResults.filter { $0.status == .outdated }
        case .current:
            model.updateCheckResults.filter { $0.status == .current }
        }
    }

    private var copyableNames: [String] {
        model.updateCheckResults
            .filter { $0.status == .missing || $0.status == .outdated }
            .map(\.suggestedName)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("手动对照 titledb 检查本地文件。转换 / 合并 / 万物转 NSP 开始前也会自动检测，并弹窗确认是否继续。只提示名称，不会下载游戏文件。")
                .foregroundStyle(.secondary)

            FileListEditor(
                files: $model.updateCheckFiles,
                extensions: ["xci", "nsp", "xcz", "nsz"],
                hint: "可拖入文件，或用下方按钮添加整个文件夹",
                allowsFolders: true
            )

            HStack {
                if let summary = model.updateCheckSummary {
                    Text("共 \(summary.games) 款 · 缺 \(summary.missing) · 可升级 \(summary.outdated) · 最新 \(summary.current)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制全部缺失/可升级名称") { copyNames(copyableNames) }
                    .disabled(copyableNames.isEmpty)
                Button("开始检测") {
                    model.checkUpdates(files: model.updateCheckFiles, recursive: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.updateCheckFiles.isEmpty)
            }

            if !model.updateCheckResults.isEmpty {
                Picker("筛选", selection: $filter) {
                    ForEach(UpdateFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Table(filtered) {
                    TableColumn("状态") { (row: UpdateCheckResult) in
                        Text(row.status.label)
                            .foregroundStyle(statusColor(row.status))
                    }
                    .width(min: 72, ideal: 88)

                    TableColumn("游戏") { (row: UpdateCheckResult) in
                        Text(row.name)
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("本地") { (row: UpdateCheckResult) in
                        Text(row.localVersion.map { "v\($0)" } ?? "无")
                            .monospacedDigit()
                    }
                    .width(60)

                    TableColumn("最新") { (row: UpdateCheckResult) in
                        Text(row.latestVersion.map { "v\($0)" } ?? "—")
                            .monospacedDigit()
                    }
                    .width(60)

                    TableColumn("更新包名称（可复制）") { (row: UpdateCheckResult) in
                        HStack(spacing: 6) {
                            Text(row.suggestedName.isEmpty ? "—" : row.suggestedName)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .help(row.suggestedName)
                            if !row.suggestedName.isEmpty {
                                Button {
                                    copyNames([row.suggestedName])
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("复制名称")
                            }
                        }
                    }
                    .width(min: 220, ideal: 320)
                }
                .frame(minHeight: 160)
            }
        }
    }

    private func statusColor(_ status: UpdateCheckStatus) -> Color {
        switch status {
        case .missing: .orange
        case .outdated: .yellow
        case .current: .green
        case .no_update_listed: .secondary
        }
    }

    private func copyNames(_ names: [String]) {
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        model.statusText = names.count == 1 ? "已复制更新包名称" : "已复制 \(names.count) 个更新包名称"
    }
}
