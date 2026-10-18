import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

// MARK: - 通用右键菜单条目
//
// 树表(NSOutlineView / NSMenu)与搜索窗口(SwiftUI contextMenu)共用同一份菜单
// 构建逻辑,再分别渲染成 AppKit / SwiftUI 菜单,避免两套菜单长期走样。

struct FileMenuEntry: Identifiable {
    let id = UUID()
    let title: String
    let icon: String?
    let enabled: Bool
    let kind: Kind

    enum Kind {
        case action(() -> Void)
        case submenu([FileMenuEntry])
        case separator
    }

    static func action(_ title: String, icon: String? = nil,
                       enabled: Bool = true,
                       handler: @escaping () -> Void) -> FileMenuEntry {
        FileMenuEntry(title: title, icon: icon, enabled: enabled, kind: .action(handler))
    }

    static func submenu(_ title: String, icon: String? = nil,
                        entries: [FileMenuEntry]) -> FileMenuEntry {
        FileMenuEntry(title: title, icon: icon, enabled: true, kind: .submenu(entries))
    }

    static func separator() -> FileMenuEntry {
        FileMenuEntry(title: "", icon: nil, enabled: true, kind: .separator)
    }
}

/// 持有闭包的菜单项目标:item.target = box,点击回调 handler(并借 representedObject 保活)
final class MenuActionBox: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run(_ sender: NSMenuItem) { handler() }
}

extension FileMenuEntry {
    /// 渲染成 AppKit 菜单项(树表右键菜单用)
    var nsMenuItem: NSMenuItem {
        let image = icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        switch kind {
        case .separator:
            return .separator()
        case .action(let handler):
            let item = NSMenuItem(title: title, action: #selector(MenuActionBox.run(_:)), keyEquivalent: "")
            let box = MenuActionBox(handler)
            item.target = box
            item.representedObject = box // 保活,防止 target 释放
            item.isEnabled = enabled
            item.image = image
            return item
        case .submenu(let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            for entry in entries { submenu.addItem(entry.nsMenuItem) }
            item.submenu = submenu
            item.image = image
            return item
        }
    }
}

/// 渲染成 SwiftUI contextMenu 内容(搜索窗口 / 详情面板用)
struct FileMenuContent: View {
    let entries: [FileMenuEntry]

    var body: some View {
        ForEach(entries) { entry in
            switch entry.kind {
            case .separator:
                Divider()
            case .action(let handler):
                Button {
                    handler()
                } label: {
                    label(entry)
                }
                .disabled(!entry.enabled)
            case .submenu(let sub):
                Menu {
                    FileMenuContent(entries: sub)
                } label: {
                    label(entry)
                }
                .disabled(!entry.enabled)
            }
        }
    }

    @ViewBuilder
    private func label(_ entry: FileMenuEntry) -> some View {
        if let icon = entry.icon {
            Label(entry.title, systemImage: icon)
        } else {
            Text(entry.title)
        }
    }
}

// MARK: - 选中项

/// 右键菜单作用的一项;多选时 items.count > 1
struct FileItem {
    let url: URL
    let isDirectory: Bool
}

// MARK: - 比较工具

/// 已安装的差异比较工具(命令里含 {paths} 占位)
struct CompareTool: Identifiable {
    var id: String { name }
    let name: String
    let command: String
}

// MARK: - 系统文件操作

@MainActor
enum FileActions {
    /// 用默认应用打开(文件夹则由访达打开)
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openAll(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func openTerminal(directory: String) {
        LauncherStore.openTerminal(at: URL(fileURLWithPath: directory))
    }

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func copyFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// 快速查看:支持多选,面板内 ←/→ 可逐项切换。
    /// 单选一张图片时,自动带上同目录下的其它图片,并以选中项为起始预览项
    /// (与 Finder 里按空格的体验一致)。
    static func quickLook(_ urls: [URL]) {
        let (list, start) = quickLookList(for: urls)
        QuickLookPreview.shared.preview(list, startAt: start)
    }

    /// 计算实际预览列表与起始下标
    static func quickLookList(for urls: [URL]) -> ([URL], Int) {
        guard urls.count == 1, let selected = urls.first, isImage(selected) else {
            return (urls, 0)
        }
        let dir = selected.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var images = siblings.filter { isImage($0) }
        guard images.count > 1 else { return (urls, 0) }
        images.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let normalized = selected.standardizedFileURL
        if let index = images.firstIndex(where: { $0.standardizedFileURL == normalized }) {
            return (images, index) // 目录顺序不变,从选中项开始预览
        }
        images.insert(selected, at: 0)
        return (images, 0)
    }

    /// 是否为图片类型(按扩展名判断)
    nonisolated static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// 用指定应用打开
    static func open(_ url: URL, with app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
            if let error { Diag.log("打开方式失败: \(error)") }
        }
    }

    /// 访达「显示简介」(⌘I)
    static func getInfo(_ url: URL) {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Diag.log("显示简介失败: \(error)") }
    }

    /// 移到废纸篓(带确认,可再拖回)
    static func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        if urls.count == 1 {
            alert.messageText = L.t("file.trash.confirm")
            alert.informativeText = urls[0].path
        } else {
            alert.messageText = L.f("file.trash.confirmN", urls.count)
            alert.informativeText = urls.map(\.path).joined(separator: "\n")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.t("file.trash"))
        alert.addButton(withTitle: L.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error { Diag.log("移到废纸篓失败: \(error)") }
        }
    }

    /// LaunchServices 枚举能打开该 URL 的应用(去重、按名称排序)。
    /// 同一应用常因注册了多个 UTI、或多份副本而重复返回,
    /// 因此按 路径 / bundle id / 显示名 三重去重。
    static func applications(for url: URL) -> [URL] {
        // 优先保留正式安装位置(/Applications、/System/Applications),
        // 而非 EdgeUpdater 等更新器缓存里的副本,保证去重后留下的是常用入口
        func rank(_ app: URL) -> Int {
            let p = app.standardizedFileURL.path
            if p.hasPrefix("/Applications/") || p.hasPrefix("/System/Applications/") { return 0 }
            if p.hasPrefix("/System/") { return 1 }
            return 2
        }
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .sorted { rank($0) < rank($1) }
        var seen = Set<String>()
        var result: [URL] = []
        for app in candidates {
            let standardized = app.standardizedFileURL
            let bundleID = Bundle(url: standardized)?.bundleIdentifier
            let name = appName(standardized).lowercased()
            let keys: [String?] = [standardized.path, bundleID, name]
            let present = keys.compactMap { $0 }
            guard present.allSatisfy({ !seen.contains($0) }) else { continue }
            present.forEach { seen.insert($0) }
            result.append(standardized)
        }
        return result.sorted { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
    }

    static func appName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// 「其他…」:手动选择一个应用
    static func chooseApplication(for url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = L.t("file.openWith.message")
        panel.prompt = L.t("common.ok")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 已安装的比较工具(Beyond Compare / FileMerge)
    static func compareTools() -> [CompareTool] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var tools: [CompareTool] = []
        for base in ["/Applications", home.appendingPathComponent("Applications").path] {
            let cli = "\(base)/Beyond Compare.app/Contents/MacOS/bcomp"
            if fm.isExecutableFile(atPath: cli) {
                tools.append(CompareTool(name: "Beyond Compare", command: "\"\(cli)\" {paths}"))
                break
            }
        }
        if fm.isExecutableFile(atPath: "/usr/bin/opendiff") {
            tools.append(CompareTool(name: "FileMerge", command: "/usr/bin/opendiff {paths}"))
        }
        return tools
    }

    /// 直接执行(不经终端)一条命令,用于比较工具等会自行弹出 GUI 的程序
    static func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            Diag.log("执行命令失败: \(error)")
        }
    }

    /// 应用内「属性」窗口:不依赖访达/自动化权限,直接展示资源信息
    static func showProperties(_ url: URL) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey,
            .contentTypeKey, .isReadableKey, .isWritableKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let isDir = values?.isDirectory ?? false

        var rows: [(String, String)] = []
        rows.append((L.t("prop.kind"),
                     values?.contentType?.localizedDescription ?? (isDir ? L.t("prop.folder") : L.t("prop.file"))))
        rows.append((L.t("prop.location"), url.deletingLastPathComponent().path))
        if !isDir {
            if let size = values?.fileSize {
                rows.append((L.t("prop.size"), Format.size(Int64(size))))
            }
            let allocated = values?.totalFileAllocatedSize ?? values?.fileSize
            if let allocated {
                rows.append((L.t("prop.allocated"), Format.size(Int64(allocated))))
            }
        }
        if let created = values?.creationDate {
            rows.append((L.t("prop.created"), Self.dateTime(created)))
        }
        if let modified = values?.contentModificationDate {
            rows.append((L.t("prop.modified"), Self.dateTime(modified)))
        }
        rows.append((L.t("prop.permissions"), permissions(url, isDirectory: isDir,
                                                          readable: values?.isReadable ?? true,
                                                          writable: values?.isWritable ?? false)))

        let grid = NSGridView(views: rows.map { label, value in
            let l = NSTextField(labelWithString: label)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            let v = NSTextField(labelWithString: value)
            v.isSelectable = true
            v.lineBreakMode = .byTruncatingMiddle
            v.maximumNumberOfLines = 2
            v.preferredMaxLayoutWidth = 320
            return [l, v]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        let alert = NSAlert()
        alert.messageText = url.lastPathComponent
        alert.accessoryView = grid
        alert.addButton(withTitle: L.t("common.ok"))
        alert.runModal()
    }

    private static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private static func permissions(_ url: URL, isDirectory: Bool,
                                    readable: Bool, writable: Bool) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mode = attrs?[.posixPermissions] as? Int
        var bits = isDirectory ? "d" : "-"
        if let mode {
            let masks: [(Int, String)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                                          (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                          (0o004, "r"), (0o002, "w"), (0o001, "x")]
            for (mask, ch) in masks { bits += (mode & mask) != 0 ? ch : "-" }
            bits += String(format: " (%03o)", mode & 0o777)
        } else {
            bits += readable ? "r" : "-"
            bits += writable ? "w" : "-"
        }
        return bits
    }
}

// MARK: - 快速查看(空格预览,支持多选与左右方向键切换)

/// 自定义预览项:标题里带上「当前/总数」,QLPreviewPanel 会将其显示在窗口标题栏
final class QuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}

/// QLPreviewPanel 需要一个常驻的 dataSource,单例持有当前预览项
@MainActor
final class QuickLookPreview: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()
    private var items: [QuickLookItem] = []

    func preview(_ urls: [URL], startAt index: Int = 0) {
        let total = urls.count
        items = urls.enumerated().map { i, url in
            let name = url.lastPathComponent
            let title = total > 1 ? L.f("quicklook.title", name, i + 1, total) : name
            return QuickLookItem(url: url, title: title)
        }
        guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = max(0, min(index, items.count - 1))
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }
}

// MARK: - 菜单构建

@MainActor
enum FileMenuFactory {
    /// 通用文件/文件夹菜单,支持多选:
    /// 打开 / 打开方式(单选) / 快速查看(可多选,方向键连播) / 属性与简介(单选)
    /// / 比较(恰两项) / 在访达中显示 / 终端 / 自定义启动器 / 收藏夹(单选文件夹)
    /// / 拷贝 / 移到废纸篓。folderExtras 用于树表追加搜索/进入/统计等文件夹操作。
    static func menuEntries(items: [FileItem],
                            launchers: LauncherStore,
                            favorites: FavoritesStore? = nil,
                            folderExtras: [FileMenuEntry] = [],
                            openImagePreview: ((URL) -> Void)? = nil) -> [FileMenuEntry] {
        guard let first = items.first else { return [] }
        let urls = items.map(\.url)
        let single = items.count == 1

        var entries: [FileMenuEntry] = []

        // 打开
        entries.append(.action(single ? L.t("file.open") : L.f("file.openN", items.count),
                               icon: "arrow.up.forward.app") {
            single ? FileActions.open(first.url) : FileActions.openAll(urls)
        })

        // 打开方式:仅单选有意义
        if single {
            let apps = FileActions.applications(for: first.url)
            var openWith: [FileMenuEntry] = apps.prefix(15).map { app in
                .action(FileActions.appName(app)) { FileActions.open(first.url, with: app) }
            }
            if !openWith.isEmpty { openWith.append(.separator()) }
            openWith.append(.action(L.t("file.openWith.other"), icon: "ellipsis.circle") {
                if let app = FileActions.chooseApplication(for: first.url) {
                    FileActions.open(first.url, with: app)
                }
            })
            entries.append(.submenu(L.t("file.openWith"), icon: "arrow.up.forward.app", entries: openWith))
        }

        entries.append(.separator())

        // 快速查看:全是文件时可用,多选时面板内 ←/→ 连播
        if items.allSatisfy({ !$0.isDirectory }) {
            entries.append(.action(single ? L.t("file.quickLook") : L.f("file.quickLookN", items.count),
                                   icon: "eye") {
                FileActions.quickLook(urls)
            })
        }

        // 图片预览(内置窗口:显示路径 / 上·下级目录跳转 / 复制路径);仅单选图片
        if single, !first.isDirectory, FileActions.isImage(first.url), let openImagePreview {
            entries.append(.action(L.t("file.imagePreview"), icon: "photo") {
                openImagePreview(first.url)
            })
        }

        // 属性 / 显示简介:仅单选
        if single {
            entries.append(.action(L.t("file.properties"), icon: "info.circle") {
                FileActions.showProperties(first.url)
            })
            entries.append(.action(L.t("file.getInfo"), icon: "info.square") {
                FileActions.getInfo(first.url)
            })
        }

        // 比较:恰好两项
        let compare = compareEntries(items: items)
        if !compare.isEmpty {
            entries.append(.submenu(L.t("file.compare"), icon: "arrow.left.arrow.right", entries: compare))
        }

        entries.append(.action(L.t("tree.reveal"), icon: "folder") { FileActions.reveal(urls) })

        let workDir = first.isDirectory ? first.url.path : first.url.deletingLastPathComponent().path
        entries.append(.action(L.t("tree.openTerminal"), icon: "terminal") {
            FileActions.openTerminal(directory: workDir)
        })
        for launcher in launchers.customs {
            entries.append(.action(launcher.name, icon: "terminal") {
                LauncherStore.runInTerminal(directory: workDir, paths: urls.map(\.path), command: launcher.command)
            })
        }
        entries.append(.action(L.t("launch.add"), icon: "plus") {
            if let name = promptText(L.t("launch.add.name"), L.t("launch.add.name.ph")),
               let command = promptText(L.t("launch.add.cmd"), L.t("launch.add.cmd.ph")) {
                launchers.add(name: name, command: command)
            }
        })
        if !launchers.customs.isEmpty {
            let removeEntries = launchers.customs.map { launcher in
                FileMenuEntry.action(launcher.name, icon: "minus.circle") {
                    launchers.remove(id: launcher.id)
                }
            }
            entries.append(.submenu(L.t("launch.remove"), icon: "minus.circle", entries: removeEntries))
        }

        // 添加到收藏夹:仅单选文件夹
        if let favorites, single, first.isDirectory {
            entries.append(.submenu(L.t("fav.add"), icon: "star", entries: favoriteEntries(
                name: first.url.lastPathComponent, path: first.url.path, favorites: favorites
            )))
        }

        // 树表追加的文件夹操作(搜索/进入/统计),排在复制/删除之前
        if !folderExtras.isEmpty {
            entries.append(.separator())
            entries.append(contentsOf: folderExtras)
        }

        entries.append(.separator())
        entries.append(.action(single ? L.t("file.copyPath") : L.f("file.copyPathsN", items.count),
                               icon: "doc.on.doc") {
            FileActions.copyPaths(urls)
        })
        entries.append(.action(L.t("file.copy"), icon: "doc.on.clipboard") {
            FileActions.copyFiles(urls)
        })
        entries.append(.separator())
        entries.append(.action(L.t("file.trash"), icon: "trash") {
            FileActions.moveToTrash(urls)
        })
        return entries
    }

    /// 树表专用:通用菜单 + 进入/统计/搜索等文件夹操作(仅单选文件夹时)
    static func treeEntries(nodes: [Node], primary: Node, store: ScanStore,
                            favorites: FavoritesStore, launchers: LauncherStore,
                            openSearch: @escaping () -> Void,
                            openImagePreview: ((URL) -> Void)? = nil) -> [FileMenuEntry] {
        let items = nodes.map { FileItem(url: $0.url, isDirectory: !$0.isFile) }
        var extras: [FileMenuEntry] = []
        if nodes.count == 1, !primary.isFile {
            extras.append(.action(L.t("tree.search"), icon: "magnifyingglass") { openSearch() })
            extras.append(.action(L.t("tree.enter"), icon: "arrow.right.circle") {
                store.openForBrowse(at: primary.url)
            })
            extras.append(.action(store.browseOnly ? L.t("tree.sizeThis") : L.t("tree.rescanRoot"),
                                  icon: "chart.bar") {
                store.startScan(at: primary.url)
            })
        }
        return menuEntries(items: items, launchers: launchers,
                           favorites: favorites, folderExtras: extras,
                           openImagePreview: openImagePreview)
    }

    /// 搜索窗口 / 详情面板:默认只带通用菜单(可选收藏)
    static func searchEntries(items: [FileItem], launchers: LauncherStore,
                              favorites: FavoritesStore?,
                              openImagePreview: ((URL) -> Void)? = nil) -> [FileMenuEntry] {
        menuEntries(items: items, launchers: launchers, favorites: favorites,
                    openImagePreview: openImagePreview)
    }

    private static func compareEntries(items: [FileItem]) -> [FileMenuEntry] {
        guard items.count == 2 else { return [] }
        let paths = items.map(\.url.path)
        return FileActions.compareTools().map { tool in
            .action(L.f("file.compareWith", tool.name), icon: "arrow.left.arrow.right") {
                FileActions.runShell(LauncherStore.expand(tool.command, paths: paths))
            }
        }
    }

    private static func favoriteEntries(name: String, path: String,
                                        favorites: FavoritesStore) -> [FileMenuEntry] {
        var entries: [FileMenuEntry] = [
            .action(L.t("fav.addTop"), icon: "star") {
                favorites.addFolder(name: name, path: path, into: nil)
            },
        ]
        for cat in favorites.categories() {
            entries.append(.action(cat.title, icon: "folder") {
                favorites.addFolder(name: name, path: path, into: cat.id)
            })
        }
        entries.append(.separator())
        entries.append(.action(L.t("fav.newCategory"), icon: "folder.badge.plus") {
            if let newName = promptText(L.t("fav.newCategory"), L.t("fav.newCategory.ph")),
               let newID = favorites.addCategory(named: newName, into: nil) {
                favorites.addFolder(name: name, path: path, into: newID)
            }
        })
        return entries
    }
}
