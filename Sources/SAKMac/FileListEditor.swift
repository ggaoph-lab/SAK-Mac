import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileListEditor: View {
    @Binding var files: [URL]
    let extensions: [String]
    var hint: String = ""
    /// When true, the picker can choose folders; dropped/picked folders are kept as folder URLs
    /// so the backend can scan them (e.g. update check).
    var allowsFolders: Bool = false

    @State private var selection = Set<URL>()
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: isDirectory(url) ? "folder" : "doc")
                        Text(url.lastPathComponent)
                        Spacer()
                        if isDirectory(url) {
                            Text("文件夹").foregroundStyle(.secondary)
                        } else {
                            Text(sizeString(url)).foregroundStyle(.secondary).monospacedDigit()
                        }
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
                        if allowsFolders {
                            Text("也可以拖入或添加包含这些文件的文件夹").font(.caption)
                        }
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
                Button("添加文件…") { pick(filesOnly: true) }
                if allowsFolders {
                    Button("添加文件夹…") { pick(filesOnly: false) }
                }
                Button("移除所选") { removeSelected() }.disabled(selection.isEmpty)
                Button("清空") { files.removeAll(); selection.removeAll() }.disabled(files.isEmpty)
                Spacer()
                Text("\(files.count) 项").foregroundStyle(.secondary)
            }
        }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard allowsFolders, !files.contains(url) else { continue }
                files.append(url)
            } else if extensions.contains(url.pathExtension.lowercased()), !files.contains(url) {
                files.append(url)
            }
        }
    }

    private func removeSelected() {
        files.removeAll { selection.contains($0) }
        selection.removeAll()
    }

    private func pick(filesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if filesOnly {
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        } else {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        }
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func sizeString(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
