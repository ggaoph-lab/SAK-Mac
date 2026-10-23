import AppKit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case toNsp, convert, compress, merge, updates, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .toNsp: "万物转 NSP"
        case .convert: "XCI ⇄ NSP 转换"
        case .compress: "NSZ / XCZ 压缩"
        case .merge: "合并本体 + 更新 + DLC"
        case .updates: "检测更新"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .toNsp: "shippingbox"
        case .convert: "arrow.left.arrow.right"
        case .compress: "archivebox"
        case .merge: "square.stack.3d.up"
        case .updates: "arrow.triangle.2.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tool: Tool? = .toNsp

    var body: some View {
        NavigationSplitView {
            List(Tool.allCases, selection: $tool) { tool in
                Label(tool.title, systemImage: tool.icon).tag(tool)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if !model.backendReady || !model.keysAvailable, tool != .settings {
                    SetupBanner { tool = .settings }
                }
                Group {
                    switch tool ?? .toNsp {
                    case .toNsp: ToNspView()
                    case .convert: ConvertView()
                    case .compress: CompressView()
                    case .merge: MergeView()
                    case .updates: UpdateCheckView()
                    case .settings: SettingsView()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()
                StatusBar()
                LogConsole()
                    .frame(height: 180)
            }
            .navigationTitle((tool ?? .toNsp).title)
            .sheet(item: Binding(
                get: { model.updateConfirm },
                set: { newValue in
                    // Dismiss via window chrome / Escape — only cancel if still pending.
                    if newValue == nil, model.updateConfirm != nil {
                        model.cancelUpdateConfirm()
                    }
                }
            )) { prompt in
                UpdateConfirmSheet(prompt: prompt)
            }
        }
    }
}

struct UpdateConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: UpdateConfirmPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更新检测提示")
                .font(.title2.bold())
            Text("任务：\(prompt.jobTitle)")
                .foregroundStyle(.secondary)

            if let failed = prompt.checkFailedMessage {
                Text("无法完成更新检测：\(failed)\n是否仍要继续运行？")
            } else {
                Text("以下游戏缺少更新或版本落后。可先复制更新包名称自行补齐，或选择仍然继续。")
            }

            if !prompt.issues.isEmpty {
                List(prompt.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(issue.status.label)
                                .foregroundStyle(issue.status == .missing ? Color.orange : Color.yellow)
                            Text(issue.name).lineLimit(1)
                            Spacer()
                            Text("本地 \(issue.localVersion.map { "v\($0)" } ?? "无") → 最新 \(issue.latestVersion.map { "v\($0)" } ?? "—")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !issue.suggestedName.isEmpty {
                            HStack {
                                Text(issue.suggestedName)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                Spacer()
                                Button {
                                    copyNames([issue.suggestedName])
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 160, maxHeight: 280)
            }

            HStack {
                if !prompt.copyableNames.isEmpty {
                    Button("复制全部更新包名称") { copyNames(prompt.copyableNames) }
                }
                Spacer()
                Button("取消") { model.cancelUpdateConfirm() }
                    .keyboardShortcut(.cancelAction)
                Button("仍然继续") { model.confirmUpdateAndContinue() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: prompt.issues.isEmpty ? 180 : 360)
    }

    private func copyNames(_ names: [String]) {
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        model.statusText = names.count == 1 ? "已复制更新包名称" : "已复制 \(names.count) 个更新包名称"
    }
}

struct SetupBanner: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(model.backendReady ? "还没有找到你的 prod.keys 密钥文件。" : "后端工具尚未安装。")
            Spacer()
            Button("前往设置", action: openSettings)
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.statusText).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isBusy {
                    Button("取消", role: .cancel) { model.cancel() }
                } else {
                    Button("打开输出文件夹") { model.revealOutput() }
                }
            }
            if model.isBusy {
                if let progress = model.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if !model.progressDetail.isEmpty {
                    Text(model.progressDetail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct LogConsole: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.log) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.log.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .contextMenu {
                Button("清空日志") { model.clearLog() }
            }
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: .primary
        case .command: .blue
        case .error: .red
        case .success: .green
        }
    }
}
