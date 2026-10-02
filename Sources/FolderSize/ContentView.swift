import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: ScanStore
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Node.ID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            Group {
                if let root = store.root {
                    FolderSplitView(store: store, root: root, selection: $selection)
                } else {
                    WelcomeView(store: store)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(store: store)
            }
        }
        .toolbar {
            // 每个 ToolbarItem 独立声明,让 AppKit 使用标准工具栏间距,避免控件粘连
            ToolbarItem {
                Button {
                    store.pickFolder()
                } label: {
                    Label(L.t("toolbar.pickFolder"), systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help(L.tip("toolbar.pickFolder"))
            }

            ToolbarItem {
                if store.isScanning {
                    Button {
                        store.cancelScan()
                    } label: {
                        Label(L.t("toolbar.stop"), systemImage: "stop.fill") // ‖
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .help(L.tip("toolbar.stop"))
                } else {
                    Button {
                        if let url = store.root?.url { store.startScan(at: url, preferCache: false) }
                    } label: {
                        Label(L.t("toolbar.rescan"), systemImage: "play.fill") // ⇒
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.root == nil)
                    .help(L.tip("toolbar.rescan"))
                }
            }

            ToolbarItem {
                Button {
                    if let root = store.root {
                        // 先激活 app 再开窗,避免窗口打开却拿不到键盘焦点
                        AppFocus.activateApp(context: "搜索按钮")
                        openWindow(value: SearchScope(
                            rootPath: root.url.path,
                            prefix: "",
                            scopeName: root.name
                        ))
                    }
                } label: {
                    // 工具栏会忽略 borderedProminent/tint,显式画蓝色胶囊保证强调效果
                    Label(L.t("toolbar.search"), systemImage: "magnifyingglass")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .fixedSize() // 防止工具栏挤压导致文字换行
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store.root == nil)
                .help(L.tip("toolbar.search"))
            }

            // 弹性撑开:左侧操作组靠左,统计控件靠右
            ToolbarItem {
                Spacer()
                    .frame(minWidth: 12, maxWidth: .infinity)
            }

            ToolbarItem {
                Picker("统计口径", selection: $store.sizeMode) {
                    ForEach(SizeMode.allCases) { mode in
                        Text(L.t(mode == .allocated ? "sizemode.allocated" : "sizemode.logical"))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .help(L.tip("toolbar.sizeMode"))
            }

            ToolbarItem {
                Toggle(L.t("toolbar.hiddenFiles"), isOn: $store.includeHidden)
                    .help(L.tip("toolbar.hiddenFiles"))
            }
        }
        .navigationTitle(store.root?.name ?? L.t("app.title"))
    }
}

// MARK: - 状态栏

struct StatusBar: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        HStack(spacing: 10) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.mini)
                Text(store.loadedFromCache == nil ? L.t("status.scanning") : L.t("status.loadingCache"))
            } else if store.root != nil {
                if store.browseOnly {
                    Label(L.t("status.browse"), systemImage: "eye")
                        .foregroundStyle(.secondary)
                } else if let cached = store.loadedFromCache {
                    Label(L.t("status.cached"), systemImage: "externaldrive.badge.clock")
                        .foregroundStyle(.green)
                        .help(L.f("status.cached.tip", Format.time(cached)))
                } else {
                    Image(systemName: store.wasCancelled ? "pause.circle" : "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(store.wasCancelled ? L.t("status.stopped") : L.t("status.done"))
                }
            } else {
                Text(L.t("status.noFolder"))
            }

            if store.browseOnly, let root = store.root {
                Text(L.f("status.browseSummary", root.sorted.count))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(L.f(
                    "status.summary",
                    Format.count(store.scannedFiles),
                    Format.size(store.scannedBytes),
                    store.elapsed
                ))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            Spacer()

            if store.errorCount > 0 {
                Label(L.f("status.errors", Format.count(store.errorCount)), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(L.f("status.errors.tip", store.lastError ?? ""))
            }

            if let root = store.root {
                Text(root.url.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.tertiary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([root.url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(L.tip("status.reveal"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }
}
