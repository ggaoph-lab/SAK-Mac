import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileListEditor: View {
    @Binding var files: [URL]
    let extensions: [String]
    var hint: String = ""

    @State private var selection = Set<URL>()
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: "doc")
                        Text(url.lastPathComponent)
                        Spacer()
                        Text(sizeString(url)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .help(url.path)
                }
                .onMove { files.move(fromOffsets: $0, toOffset: $1) }
            }
            .overlay {
                if files.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.largeTitle)
                        Text("把 \(extensions.map { "." + $0 }.joined(separator: " / ")) 文件拖到这里")
                        if !hint.isEmpty { Text(hint).font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                add(urls)
                return true
            } isTargeted: { isTargeted = $0 }
            .onDeleteCommand { removeSelected() }

            HStack {
                Button("添加文件…") { pick() }
                Button("移除所选") { removeSelected() }.disabled(selection.isEmpty)
                Button("清空") { files.removeAll(); selection.removeAll() }.disabled(files.isEmpty)
                Spacer()
                Text("\(files.count) 个文件").foregroundStyle(.secondary)
            }
        }
    }

    private func add(_ urls: [URL]) {
        for url in urls where extensions.contains(url.pathExtension.lowercased()) && !files.contains(url) {
            files.append(url)
        }
    }

    private func removeSelected() {
        files.removeAll { selection.contains($0) }
        selection.removeAll()
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func sizeString(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
