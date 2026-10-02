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
                .safeAreaInset(edge: .top, spacing: 0) {
                    if store.browseOnly { browseBar }
                }
            DetailPanel(store: store, node: selectedNode ?? root)
                .frame(minWidth: 270, idealWidth: 320, maxWidth: 380)
        }
    }

    /// 浏览模式提示条:点「统计大小」才开始统计
    private var browseBar: some View {
        HStack(spacing: 10) {
            Label(L.t("browse.bar"), systemImage: "eye")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                if let url = store.root?.url { store.startScan(at: url) }
            } label: {
                Label(L.t("browse.scan"), systemImage: "chart.bar.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("r", modifiers: .command)
            .help(L.tip("browse.scan"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// 目录树表:封装原生 NSOutlineView。
/// SwiftUI Table 的 children 展开箭头在 macOS 上不可靠(点击无响应),
/// NSOutlineView 的展开由 AppKit 保证;浏览模式的懒加载在数据源查询时同步完成,
/// 行绘制时子目录已就绪,展开箭头永远是真实的。
struct FolderTableView: NSViewRepresentable {
    @ObservedObject var store: ScanStore
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var launchers: LauncherStore
    @Environment(\.openWindow) private var openWindow
    let root: Node
    @Binding var selection: Node.ID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.rowHeight = 24
        outline.indentationPerLevel = 12
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = true

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = L.t("col.name")
        name.width = 280
        name.minWidth = 120
        name.resizingMask = [.autoresizingMask, .userResizingMask] // 随窗口拉伸,也可手动拖窄
        outline.addTableColumn(name)
        outline.outlineTableColumn = name

        for (id, colID, width, minWidth) in [
            ("size", "col.size", CGFloat(96), CGFloat(88)),
            ("percent", "col.percent", CGFloat(62), CGFloat(56)),
            ("files", "col.files", CGFloat(62), CGFloat(56)),
            ("dirs", "col.dirs", CGFloat(70), CGFloat(62)),
        ] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = L.t(colID)
            col.width = width
            col.minWidth = minWidth
            col.resizingMask = .userResizingMask
            outline.addTableColumn(col)
        }

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClick(_:))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let outline = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.syncData()
        context.coordinator.syncSelection()
    }

    // MARK: - 协调器(数据源 + 代理 + 右键菜单)

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: FolderTableView
        weak var outline: NSOutlineView?
        private var lastRootID: UUID?
        private var lastReload = Date.distantPast

        init(_ parent: FolderTableView) { self.parent = parent }

        private var store: ScanStore { parent.store }

        /// 行的子目录;浏览模式下未列出的目录在查询时同步 readdir(懒加载)
        private func children(of node: Node) -> [Node] {
            if store.browseOnly && node.browsePending {
                store.browseListIfNeeded(node)
            }
            return node.sorted
        }

        // MARK: 数据源

        func outlineView(_ outline: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: (item as? Node) ?? parent.root).count
        }

        func outlineView(_ outline: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = (item as? Node) ?? parent.root
            return node.sorted[index]
        }

        func outlineView(_ outline: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return !children(of: node).isEmpty
        }

        // MARK: 单元格

        func outlineView(_ outline: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            switch tableColumn?.identifier.rawValue {
            case "size":
                // 浏览模式:文件夹不显示大小,文件显示自身大小
                let text: String
                if store.browseOnly {
                    text = node.isFile ? Format.size(node.logical) : "—"
                } else {
                    text = Format.size(node.size(store.sizeMode))
                }
                return cell("size", text, monospaced: true, secondary: node.isFile)
            case "percent":
                return cell("percent", store.browseOnly ? "—" : percent(of: node),
                            monospaced: true, secondary: true)
            case "files":
                let pending = store.browseOnly && node.browsePending
                return cell("files", (pending || node.isFile) ? "—" : Format.count(node.files),
                            monospaced: true)
            case "dirs":
                let pending = store.browseOnly && node.browsePending
                return cell("dirs", (pending || node.isFile) ? "—" : Format.count(node.dirs),
                            monospaced: true)
            default:
                return nameCell(node)
            }
        }

        func outlineView(_ outline: NSOutlineView, toolTipFor cell: NSView, rect: NSRectPointer,
                         tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint) -> String {
            guard let node = item as? Node else { return "" }
            return store.browseOnly ? node.url.path + L.t("tree.browseNote.tip") : node.url.path
        }

        private func percent(of node: Node) -> String {
            guard let parent = node.parent else { return "100%" }
            return Format.percent(node.size(store.sizeMode), of: parent.size(store.sizeMode))
        }

        private func cell(_ id: String, _ text: String,
                          monospaced: Bool = false, secondary: Bool = false) -> NSTableCellView {
            let view = NSTableCellView()
            view.identifier = NSUserInterfaceItemIdentifier(id)
            let field = NSTextField(labelWithString: text)
            field.font = monospaced
                ? .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                : .systemFont(ofSize: 13)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            view.textField = field
            return view
        }

        private func nameCell(_ node: Node) -> NSTableCellView {
            let view = NSTableCellView()
            view.identifier = NSUserInterfaceItemIdentifier("name")
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: node.isFile ? "doc" : "folder.fill",
                                 accessibilityDescription: nil)
            icon.contentTintColor = node.isFile ? .secondaryLabelColor : .controlAccentColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(labelWithString: node.name)
            field.font = .systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(icon)
            view.addSubview(field)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            view.textField = field
            view.imageView = icon
            return view
        }

        // MARK: 选中 / 双击

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            parent.selection = (outline.item(atRow: outline.selectedRow) as? Node)?.id
        }

        @objc func doubleClick(_ sender: Any) {
            guard let outline,
                  let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }

        // MARK: 刷新与选中同步

        /// store 每次 objectWillChange 都会走 updateNSView;reloadData 按
        /// Node 引用保留展开状态。扫描进行中按 0.15s 节流,避免高频刷新
        /// 打断用户展开/选中交互(展开箭头扫描期间照样可点)
        func syncData() {
            guard let outline else { return }
            let now = Date()
            if store.isScanning, now.timeIntervalSince(lastReload) < 0.15 { return }
            lastReload = now
            outline.reloadData()
        }

        func syncSelection() {
            guard let outline else { return }
            let current = (outline.item(atRow: outline.selectedRow) as? Node)?.id
            guard current != parent.selection else { return }
            if let id = parent.selection, let node = Node.find(id, in: parent.root) {
                let row = outline.row(forItem: node)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
            outline.deselectAll(nil)
        }

        // MARK: 右键菜单

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline,
                  outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            let scope = SearchScope(
                rootPath: parent.root.url.path,
                prefix: node.relPath,
                scopeName: node.name
            )
            FolderTreeMenuBuilder.build(
                menu: menu, node: node,
                store: store, favorites: parent.favorites,
                launchers: parent.launchers,
                openSearch: { [openWindow = parent.openWindow] in
                    openWindow(value: scope)
                }
            )
        }
    }
}

// MARK: - 树表右键菜单(NSMenu 版,与侧栏菜单逻辑一致)

@MainActor
enum FolderTreeMenuBuilder {
    /// 持有闭包的菜单项目标:item.target = box,点击回调 handler
    final class ActionBox: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run(_ sender: NSMenuItem) { handler() }
    }

    static func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ActionBox.run(_:)), keyEquivalent: "")
        let box = ActionBox(handler)
        item.target = box
        item.representedObject = box // 保活,防止 target 释放
        return item
    }

    static func build(
        menu: NSMenu, node: Node, store: ScanStore,
        favorites: FavoritesStore, launchers: LauncherStore,
        openSearch: @escaping () -> Void
    ) {
        // 打开方式
        menu.addItem(item(L.t("tree.reveal")) {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        })
        menu.addItem(item(L.t("tree.openTerminal")) {
            LauncherStore.openTerminal(at: node.url)
        })
        for launcher in launchers.customs {
            menu.addItem(item(launcher.name) {
                LauncherStore.runInTerminal(path: node.url.path, command: launcher.command)
            })
        }
        if !launchers.customs.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item(L.t("launch.add")) {
            if let name = promptText(L.t("launch.add.name"), L.t("launch.add.name.ph")),
               let command = promptText(L.t("launch.add.cmd"), L.t("launch.add.cmd.ph")) {
                launchers.add(name: name, command: command)
            }
        })
        if !launchers.customs.isEmpty {
            let remove = NSMenu(title: L.t("launch.remove"))
            for launcher in launchers.customs {
                remove.addItem(item(launcher.name) { launchers.remove(id: launcher.id) })
            }
            let removeItem = NSMenuItem(title: L.t("launch.remove"), action: nil, keyEquivalent: "")
            removeItem.submenu = remove
            menu.addItem(removeItem)
        }

        // 收藏夹
        let fav = NSMenu(title: L.t("fav.add"))
        fav.addItem(item(L.t("fav.addTop")) {
            favorites.addFolder(name: node.name, path: node.url.path, into: nil)
        })
        for cat in favorites.categories() {
            fav.addItem(item(cat.title) {
                favorites.addFolder(name: node.name, path: node.url.path, into: cat.id)
            })
        }
        fav.addItem(.separator())
        fav.addItem(item(L.t("fav.newCategory")) {
            if let name = promptText(L.t("fav.newCategory"), L.t("fav.newCategory.ph")),
               let newID = favorites.addCategory(named: name, into: nil) {
                favorites.addFolder(name: node.name, path: node.url.path, into: newID)
            }
        })
        let favItem = NSMenuItem(title: L.t("fav.add"), action: nil, keyEquivalent: "")
        favItem.submenu = fav
        menu.addItem(favItem)

        // 其他
        menu.addItem(item(L.t("tree.search")) { openSearch() })
        menu.addItem(item(L.t("tree.copyPath")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        })
        menu.addItem(.separator())
        if !node.isFile {
            menu.addItem(item(L.t("tree.enter")) {
                store.openForBrowse(at: node.url)
            })
            menu.addItem(item(store.browseOnly ? L.t("tree.sizeThis") : L.t("tree.rescanRoot")) {
                store.startScan(at: node.url)
            })
        }
    }
}
