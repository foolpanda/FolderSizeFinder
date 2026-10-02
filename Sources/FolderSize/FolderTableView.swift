import SwiftUI
import AppKit

struct FolderSplitView: View {
    @ObservedObject var store: ScanStore
    let root: Node
    @Binding var selection: Node.ID?

    private var selectedNode: Node? {
        selection.flatMap { Node.find($0, in: root) } ?? root
    }

    var body: some View {
        HSplitView {
            FolderTableView(store: store, root: root, selection: $selection)
                .frame(minWidth: 440)
                .layoutPriority(1)
            DetailPanel(store: store, node: selectedNode ?? root)
                .frame(minWidth: 270, idealWidth: 320, maxWidth: 380)
        }
    }
}

struct FolderTableView: View {
    @ObservedObject var store: ScanStore
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.openWindow) private var openWindow
    let root: Node
    @Binding var selection: Node.ID?

    var body: some View {
        Table(root.sorted, children: \.tableChildren, selection: $selection) {
            TableColumn("名称") { node in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contextMenu { menu(for: node) }
                .help(node.url.path)
            }
            TableColumn("大小") { node in
                Text(Format.size(node.size(store.sizeMode)))
                    .monospacedDigit()
            }
            .width(min: 92, ideal: 102)
            TableColumn("占比") { node in
                Text(percent(of: node))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 58, ideal: 62)
            TableColumn("文件") { node in
                Text(Format.count(node.files)).monospacedDigit()
            }
            .width(min: 58, ideal: 64)
            TableColumn("文件夹") { node in
                Text(Format.count(node.dirs)).monospacedDigit()
            }
            .width(min: 58, ideal: 64)
        }
        .overlay {
            if root.sorted.isEmpty && !store.isScanning {
                Text("此文件夹没有子文件夹")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percent(of node: Node) -> String {
        guard let parent = node.parent else { return "100%" }
        return Format.percent(node.size(store.sizeMode), of: parent.size(store.sizeMode))
    }

    @ViewBuilder
    private func menu(for node: Node) -> some View {
        addFavoriteMenu(node)
        Button("在此文件夹中搜索…") {
            openWindow(value: SearchScope(
                rootPath: root.url.path,
                prefix: node.relPath,
                scopeName: node.name
            ))
        }
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Button("拷贝路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Divider()
        Button("以此文件夹为根重新扫描") {
            store.startScan(at: node.url)
        }
    }

    /// 添加到收藏夹子菜单:顶层 / 已有分类(带轨迹)/ 新建分类并收藏进去
    @ViewBuilder
    private func addFavoriteMenu(_ node: Node) -> some View {
        Menu {
            Button("收藏到顶层") {
                favorites.addFolder(name: node.name, path: node.url.path, into: nil)
            }
            ForEach(favorites.categories(), id: \.id) { cat in
                Button(cat.title) {
                    favorites.addFolder(name: node.name, path: node.url.path, into: cat.id)
                }
            }
            Divider()
            Button("新建分类…") {
                if let name = promptText("新建分类", "分类名称,如:工作 / 视频"),
                   let newID = favorites.addCategory(named: name, into: nil) {
                    favorites.addFolder(name: node.name, path: node.url.path, into: newID)
                }
            }
        } label: {
            Label("添加到收藏夹", systemImage: "star")
        }
    }
}
