import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("密钥") {
                HStack {
                    TextField("prod.keys 路径", text: $model.keysPath)
                    Button("选择…") {
                        if let url = pick(directory: false) { model.keysPath = url.path }
                    }
                }
                Label(
                    model.keysAvailable ? "已找到密钥文件" : "找不到文件",
                    systemImage: model.keysAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(model.keysAvailable ? .green : .red)
                Text("请使用 Lockpick_RCM 等工具从你自己的 Switch 上导出 prod.keys。本程序不包含、也不会下载任何密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("输出") {
                HStack {
                    TextField("输出文件夹", text: $model.outputDir)
                    Button("选择…") {
                        if let url = pick(directory: true) { model.outputDir = url.path }
                    }
                }
            }

            Section("后端") {
                Label(
                    model.backendReady ? "已内置（Python + NSC_BUILDER + nsz）" : "未就绪",
                    systemImage: model.backendReady ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(model.backendReady ? .green : .red)
                Text("转换引擎已随应用打包，无需安装系统 Python，也无需联网下载依赖。首次运行只会在本机写入一小份可写配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("修复后端") { model.repairBackend() }
                        .disabled(model.isBusy)
                    Button("在 Finder 中显示") {
                        try? FileManager.default.createDirectory(at: BackendPaths.support, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(BackendPaths.support)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pick(directory: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.canCreateDirectories = directory
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
