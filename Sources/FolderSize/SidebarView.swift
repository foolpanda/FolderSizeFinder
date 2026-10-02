import SwiftUI

struct QuickLocation: Identifiable {
    let icon: String
    let name: String
    let url: URL
    var id: String { url.path }
}

enum Locations {
    static func quick() -> [QuickLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [(String, String, URL)] = [
            ("house", "主文件夹", home),
            ("arrow.down.circle", "下载", home.appendingPathComponent("Downloads")),
            ("doc", "文稿", home.appendingPathComponent("Documents")),
            ("desktopcomputer", "桌面", home.appendingPathComponent("Desktop")),
            ("app.gift", "应用程序", URL(fileURLWithPath: "/Applications")),
            ("workspace", "工作区", home.appendingPathComponent("workspace")),
        ]
        return candidates.filter { fm.fileExists(atPath: $0.2.path) }.map {
            QuickLocation(icon: $0.0, name: $0.1, url: $0.2)
        }
    }

    static func volumes() -> [QuickLocation] {
        let fm = FileManager.default
        let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
                ?? url.lastPathComponent
            return QuickLocation(icon: "externaldrive", name: name, url: url)
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: ScanStore
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        List {
            Section("常用位置") {
                ForEach(Locations.quick()) { item in
                    row(item)
                }
            }
            Section("卷") {
                ForEach(Locations.volumes()) { item in
                    row(item)
                }
            }
            Section {
                if favorites.roots.isEmpty {
                    Text("在中间树列表右键文件夹\n→「添加到收藏夹」")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineSpacing(3)
                } else {
                    ForEach(favorites.roots) { node in
                        FavoriteBranch(node: node, store: store, favorites: favorites)
                    }
                }
            } header: {
                Text("收藏夹").contextMenu {
                    Button("新建分类…") {
                        if let name = promptText("新建分类", "分类名称,如:工作 / 视频") {
                            favorites.addCategory(named: name, into: nil)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ item: QuickLocation) -> some View {
        let isCurrent = store.root?.url.standardizedFileURL.path
            == item.url.standardizedFileURL.path
        return Button {
            store.startScan(at: item.url)
        } label: {
            Label(item.name, systemImage: item.icon)
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(item.url.path)
    }
}

// MARK: - 收藏夹分支(递归结构体:分类可无限嵌套)

private struct FavoriteBranch: View {
    let node: FavoriteNode
    @ObservedObject var store: ScanStore
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        if node.isCategory {
            DisclosureGroup(isExpanded: favorites.expandedBinding(node.id)) {
                ForEach(node.children) { child in
                    FavoriteBranch(node: child, store: store, favorites: favorites)
                }
            } label: {
                categoryRow
            }
        } else {
            favoriteRow
        }
    }

    private var categoryRow: some View {
        Button {
            favorites.toggleExpanded(node.id)
        } label: {
            Label(node.name, systemImage: "folder.fill")
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu { nodeMenu }
    }

    private var favoriteRow: some View {
        let isCurrent = store.root?.url.standardizedFileURL.path == node.path
        let missing = node.url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        return Button {
            open()
        } label: {
            Label(node.name, systemImage: missing ? "star" : "star.fill")
                .foregroundStyle(missing ? Color.secondary : (isCurrent ? Color.accentColor : .primary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(missing ? "\(node.path ?? "")(目录不存在)" : node.path ?? "")
        .contextMenu { nodeMenu }
    }

    /// 点击收藏 → 以其扫描(缓存优先);目录已不存在时提示并可一键清理
    private func open() {
        guard let url = node.url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "目录不存在或已移动"
            alert.informativeText = url.path
            alert.addButton(withTitle: "从收藏夹删除")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                favorites.remove(id: node.id)
            }
            return
        }
        store.startScan(at: url)
    }

    // MARK: 右键菜单(分类与目录收藏通用)

    @ViewBuilder
    private var nodeMenu: some View {
        Button("重命名…") {
            if let name = promptText("重命名", "名称", initial: node.name) {
                favorites.rename(id: node.id, to: name)
            }
        }
        if node.isCategory {
            Button("新建子分类…") {
                if let name = promptText("新建分类", "分类名称,如:工作 / 视频") {
                    favorites.addCategory(named: name, into: node.id)
                }
            }
        }
        moveMenu
        Divider()
        Button("从收藏夹删除", role: .destructive) {
            favorites.remove(id: node.id)
        }
    }

    /// 移动到分类子菜单:顶层 / 已有分类(带轨迹)/ 新建分类并移入
    @ViewBuilder
    private var moveMenu: some View {
        Menu("移动到分类…") {
            Button("顶层") { favorites.move(id: node.id, into: nil) }
            ForEach(favorites.categories(excluding: node.id), id: \.id) { cat in
                Button(cat.title) { favorites.move(id: node.id, into: cat.id) }
            }
            Divider()
            Button("新建分类…") {
                if let name = promptText("新建分类", "分类名称,如:工作 / 视频"),
                   let newID = favorites.addCategory(named: name, into: nil) {
                    favorites.move(id: node.id, into: newID)
                }
            }
        }
    }
}
