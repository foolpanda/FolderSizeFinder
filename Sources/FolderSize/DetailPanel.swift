import SwiftUI
import AppKit

enum DetailTab: String, CaseIterable, Identifiable {
    case breakdown = "构成"
    case topFiles = "最大文件"
    var id: String { rawValue }
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
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
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
                    Label("Finder", systemImage: "magnifyingglass")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.path, forType: .string)
                } label: {
                    Label("拷贝路径", systemImage: "doc.on.doc")
                }
                Button {
                    store.startScan(at: node.url, preferCache: false)
                } label: {
                    Label("设为根", systemImage: "arrow.down.circle")
                }
                .disabled(store.isScanning)
                Button {
                    if let rootURL = store.root?.url {
                        openWindow(value: SearchScope(
                            rootPath: rootURL.path,
                            prefix: node.relPath,
                            scopeName: node.name
                        ))
                    }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .help("打开 Everything 式搜索窗口,范围限定此文件夹")
            }
            .controlSize(.small)
        }
    }

    // MARK: - 统计

    private var statsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            stat("逻辑大小", Format.size(node.logical))
            stat("磁盘占用", Format.size(node.allocated))
            stat("文件数", Format.count(node.files))
            stat("子文件夹", Format.count(node.dirs))
            stat("占根目录", Format.percent(node.size(store.sizeMode), of: rootTotal))
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
                name: "其他(\(node.dirs - kids.count) 项 + 文件)",
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
                    Text("浏览模式:未统计大小")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("点树表右上「统计大小」开始")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else if node.sorted.isEmpty {
                Text("此文件夹没有子文件夹")
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
                Text(store.isScanning ? "正在收集…" : "暂无数据")
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
                            Button("在 Finder 中显示") {
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
