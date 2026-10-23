import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case convert, compress, merge, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: "XCI ⇄ NSP 转换"
        case .compress: "NSZ / XCZ 压缩"
        case .merge: "合并本体 + 更新 + DLC"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .convert: "arrow.left.arrow.right"
        case .compress: "archivebox"
        case .merge: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tool: Tool? = .convert

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
                    switch tool ?? .convert {
                    case .convert: ConvertView()
                    case .compress: CompressView()
                    case .merge: MergeView()
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
            .navigationTitle((tool ?? .convert).title)
        }
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
                if model.isRunning {
                    Button("取消", role: .cancel) { model.cancel() }
                } else {
                    Button("打开输出文件夹") { model.revealOutput() }
                }
            }
            if model.isRunning {
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
