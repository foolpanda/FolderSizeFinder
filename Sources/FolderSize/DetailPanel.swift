import SwiftUI
import AppKit

enum DetailTab: String, CaseIterable, Identifiable {
    case breakdown
    case topFiles
    var id: String { rawValue }
    var title: String {
        L.t(self == .breakdown ? "detail.tab.breakdown" : "detail.tab.topFiles")
    }
}

struct DetailPanel: View {
    @ObservedObject var store: ScanStore
    @Environment(\.openWindow) private var openWindow
    let node: Node

    @State private var tab: DetailTab = .breakdown

    private var rootTotal: Int64 { store.root?.size(store.sizeMode) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            statsGrid

            Divider()

            Picker("视图", selection: $tab) {
                ForEach(DetailTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == .breakdown {
                breakdown
            } else {
                topFilesList
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                Text(node.name)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(node.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                } label: {
                    Label(L.t("detail.finder"), systemImage: "magnifyingglass")
                }
                .help(L.tip("tree.reveal"))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.path, forType: .string)
                } label: {
                    Label(L.t("detail.copyPath"), systemImage: "doc.on.doc")
                }
                .help(L.tip("tree.copyPath"))
                Button {
                    store.startScan(at: node.url, preferCache: false)
                } label: {
                    Label(L.t("detail.setRoot"), systemImage: "arrow.down.circle")
                }
                .disabled(store.isScanning)
                .help(L.tip("detail.setRoot"))
                Button {
                    if let rootURL = store.root?.url {
                        openWindow(value: SearchScope(
                            rootPath: rootURL.path,
                            prefix: node.relPath,
                            scopeName: node.name
                        ))
                    }
                } label: {
                    // 与工具栏搜索按钮一致的蓝色胶囊强调
                    Label(L.t("detail.search"), systemImage: "magnifyingglass")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .fixedSize() // 按钮行窄,防止文字换行
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(L.tip("detail.search"))
            }
            .controlSize(.small)
        }
    }

    // MARK: - 统计

    private var statsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            stat(L.t("detail.logical"), Format.size(node.logical))
            stat(L.t("detail.allocated"), Format.size(node.allocated))
            stat(L.t("detail.fileCount"), Format.count(node.files))
            stat(L.t("detail.dirCount"), Format.count(node.dirs))
            stat(L.t("detail.ofRoot"), Format.percent(node.size(store.sizeMode), of: rootTotal))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 构成(环形图 + 图例)

    private var slices: [PieSlice] {
        let mode = store.sizeMode
        let kids = Array(node.sorted.prefix(7))
        var result: [PieSlice] = kids.enumerated().map { i, child in
            PieSlice(name: child.name, value: child.size(mode), color: Viz.sliceColor(i))
        }
        let shown = kids.reduce(Int64(0)) { $0 + $1.size(mode) }
        let rest = node.size(mode) - shown
        if rest > 0 {
            result.append(PieSlice(
                name: L.f("detail.other", node.dirs - kids.count),
                value: rest,
                color: Color.dynamic(Viz.other.light, Viz.other.dark)
            ))
        }
        return result
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.browseOnly {
                VStack(spacing: 6) {
                    Image(systemName: "eye")
                        .foregroundStyle(.secondary)
                    Text(L.t("detail.browseHint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L.t("detail.browseHint2"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else if node.sorted.isEmpty {
                Text(L.t("detail.noSubfolders"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                DonutChart(slices: slices, total: node.size(store.sizeMode))

                let totalVal = max(1, node.size(store.sizeMode))
                ForEach(slices) { slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 8, height: 8)
                        Text(slice.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 110, alignment: .leading)
                        MiniBar(
                            fraction: Double(slice.value) / Double(totalVal),
                            color: slice.color
                        )
                        .frame(maxWidth: .infinity)
                        Text(Format.percent(slice.value, of: node.size(store.sizeMode)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                        Text(Format.size(slice.value))
                            .monospacedDigit()
                            .frame(width: 62, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - 最大文件(全局 Top N)

    private var topFilesList: some View {
        Group {
            if store.topFiles.isEmpty {
                Text(store.isScanning ? L.t("detail.collecting") : L.t("detail.nodata"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                List(store.topFiles) { hit in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.name).lineLimit(1).truncationMode(.middle)
                            Text(hit.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(Format.size(hit.size(store.sizeMode)))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 1)
                    .contextMenu {
                        if let rootURL = store.root?.url {
                            let url = rootURL.appendingPathComponent(hit.path)
                            Button(L.t("tree.reveal")) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
