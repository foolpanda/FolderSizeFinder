import SwiftUI
import AppKit

@main
struct FolderSizeApp: App {
    @StateObject private var store = ScanStore()

    var body: some Scene {
        WindowGroup("文件夹大小") {
            ContentView(store: store)
                .environmentObject(store)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择文件夹…") { store.pickFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("重新扫描") {
                    if let url = store.root?.url { store.startScan(at: url, preferCache: false) }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("停止扫描") { store.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!store.isScanning)
                Divider()
                Button("导出索引…") { store.exportIndexPanel() }
                    .disabled(store.root == nil || store.isScanning)
                Button("打开索引…") { store.importIndexPanel() }
            }
        }

        // Everything 式搜索窗口(按 SearchScope 值打开)
        WindowGroup(for: SearchScope.self) { $scope in
            SearchWindowView(scope: scope ?? SearchScope(rootPath: "", prefix: "", scopeName: ""))
                .environmentObject(store)
        }
        .defaultSize(width: 780, height: 480)
    }
}
