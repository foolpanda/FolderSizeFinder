import SwiftUI
import AppKit

@main
struct FolderSizeApp: App {
    @StateObject private var store = ScanStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var launchers = LauncherStore()
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup(L.t("app.title")) {
            ContentView(store: store)
                .environmentObject(store)
                .environmentObject(favorites)
                .environmentObject(launchers)
                .environmentObject(settings)
                .id(settings.language) // 语言切换时整树重建,文案即时生效
                .onAppear { AppFocus.activateApp(context: "主窗口") }
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L.t("menu.pickFolder")) { store.pickFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button(L.t("menu.rescan")) {
                    if let url = store.root?.url { store.startScan(at: url, preferCache: false) }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button(L.t("menu.stopScan")) { store.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!store.isScanning)
                Divider()
                Button(L.t("menu.exportIndex")) { store.exportIndexPanel() }
                    .disabled(store.root == nil || store.isScanning)
                Button(L.t("menu.importIndex")) { store.importIndexPanel() }
            }
        }

        // 设置(语言;后续主题等)
        Settings {
            SettingsView()
                .environmentObject(settings)
                .id(settings.language)
        }

        // Everything 式搜索窗口(按 SearchScope 值打开)
        WindowGroup(for: SearchScope.self) { $scope in
            SearchWindowView(scope: scope ?? SearchScope(rootPath: "", prefix: "", scopeName: ""))
                .environmentObject(store)
                .environmentObject(settings)
                .id(settings.language)
        }
        .defaultSize(width: 780, height: 480)
    }
}
