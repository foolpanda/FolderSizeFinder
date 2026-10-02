import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor.opacity(0.85))

            Text(L.t("welcome.title"))
                .font(.title.bold())

            Text(L.t("welcome.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.pickFolder()
            } label: {
                Label(L.t("welcome.pick"), systemImage: "folder.badge.plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
            .help(L.tip("welcome.pick"))

            dropZone

            HStack(spacing: 8) {
                Text(L.t("welcome.quickStart"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(Locations.quick().prefix(5)) { item in
                    Button(item.name) {
                        store.openForBrowse(at: item.url)
                    }
                    .controlSize(.small)
                    .help(item.url.path)
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
            Label(L.t("welcome.drop"), systemImage: "arrow.down.doc")
                .foregroundStyle(.secondary)
        }
        .frame(width: 360, height: 110)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.hasDirectoryPath }) else { return false }
            store.openForBrowse(at: url)
            return true
        }
    }
}
