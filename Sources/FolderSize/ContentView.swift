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
            ToolbarItemGroup {
                Button {
                    store.pickFolder()
                } label: {
                    Label("选择文件夹…", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    if let url = store.root?.url { store.startScan(at: url, preferCache: false) }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.root == nil)

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
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store.root == nil)

                if store.isScanning {
                    Button {
                        store.cancelScan()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                }

                ProgressView()
                    .controlSize(.small)
                    .opacity(store.isScanning ? 1 : 0)
                    .help(store.isScanning ? "正在扫描" : "")

                Spacer()

                Picker("统计口径", selection: $store.sizeMode) {
                    ForEach(SizeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .help("磁盘占用 = 实际分配的块大小;逻辑大小 = 文件字节数")

                Toggle("隐藏文件", isOn: $store.includeHidden)
                    .help("是否包含以 . 开头的隐藏文件(切换后重新扫描)")
            }
        }
        .navigationTitle(store.root?.name ?? "文件夹大小")
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
                Text(store.loadedFromCache == nil ? "正在扫描…" : "正在载入缓存…")
            } else if store.root != nil {
                if let cached = store.loadedFromCache {
                    Label("已载入缓存", systemImage: "externaldrive.badge.clock")
                        .foregroundStyle(.green)
                        .help("数据来自本地索引缓存(保存于 \(Format.time(cached))。\n点击工具栏\"重新扫描\"获取最新数据。")
                } else {
                    Image(systemName: store.wasCancelled ? "pause.circle" : "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(store.wasCancelled ? "已停止" : "完成")
                }
            } else {
                Text("未选择文件夹")
            }

            Text("\(Format.count(store.scannedFiles)) 个文件 · \(Format.size(store.scannedBytes)) · \(String(format: "%.1f s", store.elapsed))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            if store.errorCount > 0 {
                Label("\(Format.count(store.errorCount)) 项无法读取", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help((store.lastError ?? "") + "\n(通常是无权限的系统目录)")
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
                .help("在 Finder 中显示")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }
}
