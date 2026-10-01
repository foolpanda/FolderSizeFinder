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
