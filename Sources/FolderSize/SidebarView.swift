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
            ("house", "loc.home", home),
            ("arrow.down.circle", "loc.downloads", home.appendingPathComponent("Downloads")),
            ("doc", "loc.documents", home.appendingPathComponent("Documents")),
            ("desktopcomputer", "loc.desktop", home.appendingPathComponent("Desktop")),
            ("app.gift", "loc.apps", URL(fileURLWithPath: "/Applications")),
            ("workspace", "loc.workspace", home.appendingPathComponent("workspace")),
        ]
        return candidates.filter { fm.fileExists(atPath: $0.2.path) }.map {
            QuickLocation(icon: $0.0, name: L.t($0.1), url: $0.2)
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
            Section(L.t("sidebar.quick")) {
                ForEach(Locations.quick()) { item in
                    row(item)
                }
            }
            Section(L.t("sidebar.volumes")) {
                ForEach(Locations.volumes()) { item in
                    row(item)
                }
            }
            Section {
                if favorites.roots.isEmpty {
                    Text(L.t("sidebar.favEmpty"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineSpacing(3)
                } else {
                    ForEach(favorites.roots) { node in
                        FavoriteBranch(node: node, store: store, favorites: favorites)
                    }
                }
            } header: {
                Text(L.t("sidebar.favorites")).contextMenu {
                    Button(L.t("fav.newCategory")) {
                        if let name = promptText(L.t("fav.newCategory"), L.t("fav.newCategory.ph")) {
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
            store.openSmart(at: item.url)
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

    /// 点击收藏 → 智能打开(有缓存秒载大小,无缓存浏览模式);目录已不存在时提示并可一键清理
    private func open() {
        guard let url = node.url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = L.t("fav.missing")
            alert.informativeText = url.path
            alert.addButton(withTitle: L.t("fav.delete"))
            alert.addButton(withTitle: L.t("common.cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                favorites.remove(id: node.id)
            }
            return
        }
        store.openSmart(at: url)
    }

    // MARK: 右键菜单(分类与目录收藏通用)

    @ViewBuilder
    private var nodeMenu: some View {
        if let url = node.url {
            LauncherMenuItems(url: url)
            Divider()
        }
        Button(L.t("fav.rename")) {
            if let name = promptText(L.t("fav.rename.name"), L.t("fav.rename.ph"), initial: node.name) {
                favorites.rename(id: node.id, to: name)
            }
        }
        if node.isCategory {
            Button(L.t("fav.newSub")) {
                if let name = promptText(L.t("fav.newCategory"), L.t("fav.newCategory.ph")) {
                    favorites.addCategory(named: name, into: node.id)
                }
            }
        }
        moveMenu
        Divider()
        Button(L.t("fav.delete"), role: .destructive) {
            favorites.remove(id: node.id)
        }
    }

    /// 移动到分类子菜单:顶层 / 已有分类(带轨迹)/ 新建分类并移入
    @ViewBuilder
    private var moveMenu: some View {
        Menu(L.t("fav.move")) {
            Button(L.t("fav.top")) { favorites.move(id: node.id, into: nil) }
            ForEach(favorites.categories(excluding: node.id), id: \.id) { cat in
                Button(cat.title) { favorites.move(id: node.id, into: cat.id) }
            }
            Divider()
            Button(L.t("fav.newCategory")) {
                if let name = promptText(L.t("fav.newCategory"), L.t("fav.newCategory.ph")),
                   let newID = favorites.addCategory(named: name, into: nil) {
                    favorites.move(id: node.id, into: newID)
                }
            }
        }
    }
}
