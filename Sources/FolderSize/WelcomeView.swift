import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor.opacity(0.85))

            Text("文件夹大小")
                .font(.title.bold())

            Text("统计任意文件夹中每个子文件夹与文件的大小占用,\n边扫描边出结果。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.pickFolder()
            } label: {
                Label("选择文件夹…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)

            dropZone

            HStack(spacing: 8) {
                Text("快速开始:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(Locations.quick().prefix(5)) { item in
                    Button(item.name) {
                        store.startScan(at: item.url)
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.4))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            Label("或将文件夹拖到此处", systemImage: "arrow.down.doc")
                .foregroundStyle(.secondary)
        }
        .frame(width: 360, height: 110)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.hasDirectoryPath }) else { return false }
            store.startScan(at: url)
            return true
        }
    }
}
