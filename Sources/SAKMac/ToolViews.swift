import SwiftUI

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
                    .disabled(model.isRunning || model.convertFiles.isEmpty)
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
                    .disabled(model.isRunning || decompressible.isEmpty)
                Button("压缩 \(compressible.count) 个") {
                    model.compress(files: compressible, level: level, verify: verify)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || compressible.isEmpty)
            }
        }
    }
}

struct MergeView: View {
    @Environment(AppModel.self) private var model
    @State private var target: MergeTarget = .xci

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
                    .disabled(model.isRunning || model.mergeFiles.count < 2)
            }
        }
    }
}
