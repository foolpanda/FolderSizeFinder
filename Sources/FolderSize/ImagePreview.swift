import SwiftUI
import AppKit

// MARK: - 图片预览窗口

/// 打开内置图片预览窗口的定位信息(初始图片绝对路径;Codable 供 openWindow 使用)
struct ImagePreviewScope: Codable, Hashable {
    let filePath: String
}

/// 目录内图片/子目录枚举(非递归,按名称自然排序,跳过隐藏项)
enum ImageFolder {
    static func images(in directory: URL) -> [URL] {
        contents(of: directory)
            .filter { FileActions.isImage($0) }
    }

    static func subdirectories(of directory: URL) -> [URL] {
        contents(of: directory).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}

/// 内置图片预览:显示图片 / 全路径,可翻页、可上/下级目录跳转、可复制路径
struct ImagePreviewWindow: View {
    let scope: ImagePreviewScope

    @State private var directory: URL
    @State private var images: [URL] = []
    @State private var index = 0
    @State private var image: NSImage?
    @State private var loadTask: Task<Void, Never>?

    init(scope: ImagePreviewScope) {
        self.scope = scope
        let url = URL(fileURLWithPath: scope.filePath)
        _directory = State(initialValue: url.deletingLastPathComponent())
    }

    private var current: URL? { images.indices.contains(index) ? images[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            imageArea
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 460)
        .navigationTitle(L.t("preview.title"))
        .onAppear {
            AppFocus.activateApp(context: "图片预览")
            loadDirectory(preferring: URL(fileURLWithPath: scope.filePath))
        }
        .onChange(of: index) { _, _ in loadImage() }
        .background {
            // 左右方向键翻页(隐藏按钮承载快捷键,与搜索窗口 Esc 同思路)
            Group {
                Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - 顶部:目录导航 + 路径

    private var toolbar: some View {
        let subdirectories = ImageFolder.subdirectories(of: directory)
        return HStack(spacing: 8) {
            Button {
                goParent()
            } label: {
                Label(L.t("preview.parent"), systemImage: "arrow.up")
            }
            .help(L.t("preview.parent"))
            .disabled(directory.deletingLastPathComponent().path == directory.path)

            Menu {
                if subdirectories.isEmpty {
                    Text(L.t("preview.noSubdir"))
                } else {
                    ForEach(subdirectories, id: \.self) { sub in
                        Button(sub.lastPathComponent) { goChild(sub) }
                    }
                }
            } label: {
                Label(L.t("preview.child"), systemImage: "arrow.down")
            }
            .help(L.t("preview.child"))
            .fixedSize()

            Text(current?.path ?? directory.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let current { FileActions.copyPaths([current]) }
            } label: {
                Label(L.t("preview.copyFull"), systemImage: "doc.on.doc")
            }
            .help(L.t("preview.copyFull"))
            .disabled(current == nil)
            .fixedSize()

            Button {
                if let current { FileActions.copyPaths([current.deletingLastPathComponent()]) }
            } label: {
                Label(L.t("preview.copyParent"), systemImage: "doc.on.doc")
            }
            .help(L.t("preview.copyParent"))
            .disabled(current == nil)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - 图片

    private var imageArea: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if images.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(L.t("preview.noImage"))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部:文件名 + 计数

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(current?.lastPathComponent ?? "—")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if images.count > 1 {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help(L.t("preview.prev"))
                Text(L.f("preview.count", index + 1, images.count))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help(L.t("preview.next"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - 动作

    private func loadDirectory(preferring preferred: URL?) {
        images = ImageFolder.images(in: directory)
        if let preferred,
           let i = images.firstIndex(where: {
               $0.standardizedFileURL == preferred.standardizedFileURL
           }) {
            index = i
        } else {
            index = 0
        }
        loadImage()
    }

    private func loadImage() {
        loadTask?.cancel()
        guard let url = current else {
            image = nil
            return
        }
        image = nil
        let target = url
        loadTask = Task.detached(priority: .userInitiated) {
            let data = try? Data(contentsOf: target)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                image = data.flatMap { NSImage(data: $0) }
            }
        }
    }

    private func step(_ delta: Int) {
        guard images.count > 1 else { return }
        index = (index + delta + images.count) % images.count
    }

    private func goParent() {
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        directory = parent
        loadDirectory(preferring: nil)
    }

    private func goChild(_ url: URL) {
        directory = url
        loadDirectory(preferring: nil)
    }
}
