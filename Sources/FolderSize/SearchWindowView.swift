import SwiftUI
import AppKit

/// Everything 式实时搜索窗口
///
/// 布局:第一行 范围全路径 / 第二行 关键词输入框 / 第三行 示例行(收起占一行,
/// 点击"搜索示例"浮出面板展示全部示例与最近搜索) / 结果列表
struct SearchWindowView: View {
    let scope: SearchScope
    @EnvironmentObject var store: ScanStore

    @State private var query = ""
    @State private var result: [FileRecord] = []
    @State private var totalHits = 0
    @State private var searchMillis = 0
    @State private var sortKey: SortKey = .name
    @State private var descending = false
    @State private var selection: FileRecord.ID?
    @State private var searchTask: Task<Void, Never>?
    @State private var showExamples = false

    private let displayCap = 20_000

    private var queryTrimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var scopeValid: Bool {
        store.root?.url.path == scope.rootPath
    }

    var body: some View {
        VStack(spacing: 0) {
            scopeRow
            Divider()
            inputRow
            examplesRow
            Divider()
            content
        }
        .frame(minWidth: 680, minHeight: 400)
        .navigationTitle("搜索 — \(scope.scopeName)")
        .onAppear {
            AppFocus.activateApp(context: "搜索窗口")
            Diag.log("窗口出现 scope=\(scope.absolutePath)")
            store.ensureSearchIndex() // 浏览模式:有缓存则后台装进搜索索引
            runSearch()
        }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: sortKey) { _, _ in runSearch() }
        .onChange(of: descending) { _, _ in runSearch() }
        .onChange(of: store.indexCount) { _, _ in runSearch() } // 扫描进行中持续更新
        .onReceive(NotificationCenter.default.publisher(for: SearchField.beganEditing)) { _ in
            // 点击/聚焦输入框 → 收起示例面板
            if showExamples { showExamples = false }
        }
        .background {
            // Esc 收起示例面板
            Button("收起") { showExamples = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - 第一行:待搜索的全路径

    private var scopeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            Text(scope.absolutePath)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(scope.absolutePath, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("拷贝此路径")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 第二行:关键词输入框

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            SearchField(text: $query)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("清空关键词")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: - 第三行:示例(收起占一行,点击浮出面板)

    /// 用窗口内浮动面板而非 SwiftUI .popover:popover 是独立窗口,
    /// 会抢走 key 状态导致输入框收不到键盘事件。
    private var examplesRow: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showExamples.toggle()
                    }
                } label: {
                    Label("搜索示例", systemImage: showExamples ? "chevron.up" : "chevron.down")
                        .font(.callout)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("浮出面板展示各种搜索场景示例,点击即用")

                Text("语法:多词空格 = AND · *.通配符 · ext:扩展名 · size:>10mb · size:<1gb · folder: 只看文件夹")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if showExamples {
                ExamplesPanel(
                    onPick: { picked in
                        query = picked
                        showExamples = false
                        // 选完把键盘焦点还给输入框
                        NotificationCenter.default.post(name: SearchField.refocus, object: nil)
                    },
                    onClose: {
                        withAnimation(.easeOut(duration: 0.15)) { showExamples = false }
                    }
                )
                .padding(.leading, 10)
                .offset(y: 34) // 悬浮于示例行下方(浮在结果区上方,不占布局)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .zIndex(10)
            }
        }
        .zIndex(2) // 保证面板浮在结果列表之上
    }

    // MARK: - 结果

    @ViewBuilder
    private var content: some View {
        if !scopeValid {
            hint("根目录已变更(\(scope.rootPath))\n请回到主窗口重新打开搜索")
        } else if store.browseOnly && store.indexCount == 0 && !store.isScanning {
            hint("浏览模式未统计,还没有可搜索的索引\n回主窗口点「统计大小」后即可全文搜索")
        } else if queryTrimmed.isEmpty {
            hint("点\"搜索示例\"浮出面板参考写法,或直接输入关键词\n空格分隔多个关键词(AND),按相对路径匹配,输入即出结果")
        } else if result.isEmpty {
            hint(store.isScanning ? "搜索中…" : "没有匹配项")
        } else {
            Table(result, selection: $selection) {
                TableColumn("名称") { rec in
                    HStack(spacing: 6) {
                        Image(systemName: rec.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(rec.isDirectory ? Color.accentColor : .secondary)
                        Text(rec.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contextMenu { rowMenu(rec) }
                    .help(rec.relPath)
                }
                TableColumn("所在文件夹") { rec in
                    Text(rec.parentPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                TableColumn("大小") { rec in
                    Text(rec.isDirectory ? "—" : Format.size(rec.logical))
                        .monospacedDigit()
                }
                .width(min: 88, ideal: 94)
            }
            .onTapGesture(count: 2) { revealSelected() }

            Divider()

            footer
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("命中 \(Format.count(totalHits)) 条"
                + (totalHits > displayCap ? "(显示前 \(Format.count(displayCap)))" : ""))
            Text("\(searchMillis) ms")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("排序")
                .foregroundStyle(.secondary)
            Picker("排序", selection: $sortKey) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            Button {
                descending.toggle()
            } label: {
                Image(systemName: descending ? "arrow.down" : "arrow.up")
            }
            .buttonStyle(.borderless)
            .help(descending ? "当前降序" : "当前升序")

            Text("索引 \(Format.count(store.indexCount)) 项")
                .foregroundStyle(.secondary)
            if store.isScanning {
                ProgressView()
                    .controlSize(.mini)
            }
            if let cached = store.loadedFromCache {
                Label("缓存", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .help("索引来自本地缓存,保存于 \(Format.time(cached))")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 动作

    private func runSearch() {
        searchTask?.cancel()
        guard scopeValid, !queryTrimmed.isEmpty else {
            result = []
            totalHits = 0
            searchMillis = 0
            return
        }
        let q = queryTrimmed
        let prefix = scope.prefix
        let snapshot = store.index // CoW 快照,后台过滤安全
        let key = sortKey
        let desc = descending
        let cap = displayCap
        searchTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 120_000_000) // 合并连击
            guard !Task.isCancelled else { return }
            let outcome = SearchFilter.filter(
                records: snapshot, prefix: prefix, query: q,
                cap: cap, key: key, descending: desc
            )
            await MainActor.run {
                guard !Task.isCancelled else { return }
                result = outcome.items
                totalHits = outcome.total
                searchMillis = outcome.millis
            }
        }
    }

    private func absoluteURL(_ rec: FileRecord) -> URL? {
        guard let rootURL = store.root?.url else { return nil }
        return rootURL.appendingPathComponent(rec.relPath)
    }

    private func revealSelected() {
        guard let sel = selection,
              let rec = result.first(where: { $0.id == sel }),
              let url = absoluteURL(rec) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    private func rowMenu(_ rec: FileRecord) -> some View {
        if let url = absoluteURL(rec) {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }
}

// MARK: - 浮动示例面板(窗口内,不抢键盘焦点)

private struct ExamplesPanel: View {
    let onPick: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("点击示例填入搜索框(覆盖常用场景):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("收起")
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SearchExample.all) { example in
                        pickRow(example.query, note: example.note)
                    }

                    let history = SearchHistory.recent
                    if !history.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        Text("最近搜索:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(history, id: \.self) { q in
                            pickRow(q, note: "")
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(12)
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    private func pickRow(_ display: String, note: String) -> some View {
        Button {
            onPick(display)
        } label: {
            HStack(spacing: 8) {
                Text(display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                if !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 最近搜索

enum SearchHistory {
    private static let key = "RecentSearches"

    static var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(8)), forKey: key) }
    }

    static func record(_ q: String) {
        var list = recent.filter { $0 != q }
        list.insert(q, at: 0)
        recent = list
    }
}

// MARK: - 原生输入框(可靠获得键盘焦点)

/// 焦点处理:openWindow 弹出的窗口默认不是 key window,须等窗口挂载后
/// 激活 app → makeKeyAndOrderFront → makeFirstResponder,按需重试;
/// 并监听"窗口成为 key"与 refocus 通知,点回窗口/选完示例都自动回到输入框。
struct SearchField: NSViewRepresentable {
    @Binding var text: String

    /// 请求把键盘焦点还给输入框(选完示例后由外部发送)
    static let refocus = Notification.Name("FolderSizeSearchRefocus")
    /// 输入框获得编辑焦点(视图层据此收起示例面板)
    static let beganEditing = Notification.Name("FolderSizeSearchBeganEditing")

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "输入关键词,例如:png / *.pdf / size:>100mb / folder:"
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.field = field
        context.coordinator.takeFocus()
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        weak var field: NSTextField?
        private var observers: [NSObjectProtocol] = []

        init(_ parent: SearchField) {
            self.parent = parent
        }

        /// 窗口挂载时机不定,系统也可能暂拒激活,因此按需重试(间隔 0.12s,最多 ~3s)
        func takeFocus(attempt: Int = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, let field = self.field else { return }
                guard let window = field.window else {
                    if attempt < 25 { self.takeFocus(attempt: attempt + 1) }
                    return
                }
                if attempt == 0 {
                    Diag.log("输入框挂载窗口: appActive=\(NSApp.isActive) keyWindow=\(window.isKeyWindow)")
                }
                // 分级激活只在首次尝试时发起,重试轮询只负责补 makeKey/makeFirstResponder,
                // 避免重试循环里反复叠加升级档位的激活请求
                if attempt == 0 { AppFocus.activateApp(context: "搜索输入框") }
                window.makeKeyAndOrderFront(nil)
                let ok = window.makeFirstResponder(field)
                if attempt == 0 {
                    Diag.log("makeFirstResponder ok=\(ok) first=\(String(describing: type(of: window.firstResponder)))")
                }

                // 激活是异步的:窗口真正成为 key 的那一刻再补一次聚焦
                if observerCount == 0 {
                    observers.append(NotificationCenter.default.addObserver(
                        forName: NSWindow.didBecomeKeyNotification,
                        object: window, queue: .main
                    ) { [weak self] _ in
                        self?.focusIfPossible()
                    })
                    observers.append(NotificationCenter.default.addObserver(
                        forName: SearchField.refocus, object: nil, queue: .main
                    ) { [weak self] _ in
                        self?.focusIfPossible()
                    })
                    observerCount = 2
                }
                if !window.isKeyWindow, attempt < 25 {
                    Diag.log("窗口未成为 key,重试 #\(attempt + 1)")
                    takeFocus(attempt: attempt + 1)
                }
            }
        }

        private var observerCount = 0

        private func focusIfPossible() {
            guard let field, let window = field.window, window.isKeyWindow else { return }
            window.makeFirstResponder(field)
        }

        // MARK: 输入回调

        func controlTextDidBeginEditing(_ note: Notification) {
            Diag.log("键盘焦点进入输入框 ✓")
            NotificationCenter.default.post(name: SearchField.beganEditing, object: nil)
        }

        func controlTextDidChange(_ note: Notification) {
            parent.text = field?.stringValue ?? ""
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let q = parent.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { SearchHistory.record(q) }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

// MARK: - 焦点诊断日志(排查"无法输入"用)

enum Diag {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderSize/search-debug.log")
    }

    static func log(_ message: String) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = Data((Format.time(Date()) + "  " + message + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
