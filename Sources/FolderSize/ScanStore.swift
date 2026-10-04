import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// 扫描状态与增量建树(全部在主线程)
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var root: Node?
    @Published private(set) var isScanning = false
    @Published private(set) var wasCancelled = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var scannedBytes: Int64 = 0
    @Published private(set) var errorCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var topFiles: [FileHit] = []
    @Published private(set) var loadedFromCache: Date?

    /// 全量索引(Everything 式搜索的数据源)
    @Published private(set) var indexCount = 0
    private(set) var index: [FileRecord] = []

    /// 浏览模式:仅列出顶层文件夹,未统计大小(点「统计大小」/ 重新扫描才进入统计)
    @Published private(set) var browseOnly = false

    @Published var sizeMode: SizeMode = .allocated {
        didSet {
            guard !browseOnly else { return } // 浏览模式没有大小可排,避免打乱目录名序
            if oldValue != sizeMode { resortAll() }
        }
    }
    @Published var includeHidden = true {
        didSet {
            guard oldValue != includeHidden, let url = root?.url else { return }
            if browseOnly {
                openForBrowse(at: url) // 浏览模式下只重新列目录
            } else {
                startScan(at: url, preferCache: false) // 口径变了,缓存作废
            }
        }
    }

    private var scanTask: Task<Void, Never>?
    private var ticker: AnyCancellable?
    private var startedAt: Date?

    // 建树状态
    private var stack: [Node] = []       // stack[0] = 根
    private var dirty: Set<Node> = []
    private var generation = 0
    private var minTopSize: Int64 = 0

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--path"), i + 1 < args.count {
            let raw = (args[i + 1] as NSString).expandingTildeInPath
            // --scan:强制重新扫描刷新缓存;否则智能打开(有缓存秒载,无缓存浏览模式)
            if args.contains("--scan") {
                startScan(at: URL(fileURLWithPath: raw))
            } else {
                openSmart(at: URL(fileURLWithPath: raw))
            }
        }
    }

    // MARK: - 控制

    /// 智能打开:该目录已有缓存 → 直接秒载缓存显示 size/占比(状态栏标注缓存时间);
    /// 没有缓存 → 浏览模式(只列顶层,秒开)。所有常规打开入口走这里。
    func openSmart(at url: URL) {
        if IndexCache.exists(for: url) {
            startScan(at: url, preferCache: true)
        } else {
            openForBrowse(at: url)
        }
    }

    /// 浏览模式:只列出 url 的顶层子文件夹(同步、秒开),不统计大小。
    /// 所有"打开目录"的入口(侧栏 / 收藏夹 / 拖拽 / --path)默认走这里,
    /// 需要大小数据时再点「统计大小」或 ⌘R 进入统计。
    func openForBrowse(at url: URL) {
        scanTask?.cancel()
        generation += 1

        let node = Node(url: url, relPath: "")
        listChildren(of: node)

        root = node
        stack = [node]
        dirty = []
        browseOnly = true
        topFiles = []
        minTopSize = 0
        index = []
        indexCount = 0
        scannedFiles = 0
        scannedBytes = 0
        errorCount = 0
        lastError = nil
        elapsed = 0
        wasCancelled = false
        loadedFromCache = nil
        isScanning = false
        ticker?.cancel()
        ticker = nil
        objectWillChange.send()
    }

    /// 浏览模式下点开搜索窗口时:若本地有该目录的索引缓存,后台静默装载进搜索索引
    /// (不重建可视树,不改变浏览状态);无缓存则搜索页会提示先统计。
    func ensureSearchIndex() {
        guard browseOnly, index.isEmpty, let url = root?.url else { return }
        let cacheURL = IndexCache.cacheURL(for: url)
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let cached = IndexCache.read(url: cacheURL) else { return }
            let records = cached.events.enumerated().map { i, event in
                FileRecord(
                    id: i,
                    relPath: event.path,
                    lowercasedPath: event.path.lowercased(),
                    isDirectory: event.isDirectory,
                    logical: event.logical,
                    allocated: event.allocated
                )
            }
            await self?.installSearchIndex(records, generation: gen)
        }
    }

    @MainActor
    private func installSearchIndex(_ records: [FileRecord], generation gen: Int) {
        guard gen == self.generation, browseOnly, index.isEmpty else { return }
        index = records
        indexCount = records.count
        objectWillChange.send()
    }

    // MARK: - 浏览模式懒加载展开

    /// 浏览模式懒加载:未 readdir 过的目录列出子目录并填充 文件/文件夹 数量。
    /// 由 NSOutlineView 数据源在绘制/展开行时同步调用——AppKit 展开前必查询,
    /// 因此展开箭头永远是真实子节点,不存在"点了展开却没内容"的时序问题
    func browseListIfNeeded(_ node: Node) {
        guard browseOnly, node.browsePending else { return }
        listChildren(of: node)
    }

    /// readdir node 的直接条目:建子目录树(sorted)、直接子文件夹数(dirs)、
    /// 直接文件数(files);浏览模式下文件也作为叶子行列出(带自身大小),
    /// 子目录标记 pending,等它们可见时再各自懒加载
    private func listChildren(of node: Node) {
        node.browsePending = false
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        var dirs: [Node] = []
        var files: [Node] = []
        var fileCount = 0
        for entry in entries {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let child = Node(
                    url: entry,
                    relPath: node.relPath.isEmpty
                        ? entry.lastPathComponent
                        : node.relPath + "/" + entry.lastPathComponent,
                    parent: node
                )
                child.browsePending = true
                node.children[entry.lastPathComponent] = child
                dirs.append(child)
            } else {
                fileCount += 1
                let child = Node(
                    url: entry,
                    relPath: node.relPath.isEmpty
                        ? entry.lastPathComponent
                        : node.relPath + "/" + entry.lastPathComponent,
                    parent: node
                )
                child.isFile = true
                let values = try? entry.resourceValues(
                    forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
                child.logical = Int64(values?.fileSize ?? 0)
                child.allocated = Int64(values?.totalFileAllocatedSize ?? 0)
                files.append(child)
            }
        }
        node.dirs = dirs.count
        node.files = fileCount
        // 文件夹在前,各自按目录名自然排序
        node.sorted = (dirs.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        } + files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    /// - Parameter preferCache: 优先加载本地缓存索引(命中则不再扫描)
    func startScan(at url: URL, preferCache: Bool = true) {
        scanTask?.cancel()
        generation += 1
        let gen = generation
        reset(for: url)

        let hidden = includeHidden
        let cacheURL = IndexCache.cacheURL(for: url)
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 1) 有缓存:重放建树,秒出结果
            if preferCache, let cached = IndexCache.read(url: cacheURL) {
                for chunk in cached.events.chunked(into: 8192) {
                    await self?.apply(chunk, generation: gen)
                }
                await self?.finish(
                    errorCount: 0, generation: gen,
                    cacheDate: cached.savedAt, scannedRoot: nil
                )
                return
            }
            // 2) 无缓存:真正扫描
            let errors = await DirectoryScanner.scan(root: url, includeHidden: hidden) { [weak self] batch in
                await self?.apply(batch, generation: gen)
            }
            await self?.finish(
                errorCount: errors, generation: gen,
                cacheDate: nil, scannedRoot: url
            )
        }
    }

    func cancelScan() {
        wasCancelled = true
        scanTask?.cancel()
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("openpanel.message")
        panel.prompt = L.t("openpanel.prompt")
        if panel.runModal() == .OK, let url = panel.url {
            openSmart(at: url)
        }
    }

    /// 打开导出的 .fsidx 文件,原样重建树与索引
    func loadIndex(from fileURL: URL) {
        scanTask?.cancel()
        generation += 1
        let gen = generation
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let cached = IndexCache.read(url: fileURL) else {
                await self?.noteLoadFailure()
                return
            }
            await self?.reset(url: URL(fileURLWithPath: cached.rootPath))
            for chunk in cached.events.chunked(into: 8192) {
                await self?.apply(chunk, generation: gen)
            }
            await self?.finish(
                errorCount: 0, generation: gen,
                cacheDate: cached.savedAt, scannedRoot: nil
            )
        }
    }

    /// 导出当前索引到用户选择的文件
    func exportIndexPanel() {
        guard let rootURL = root?.url else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let name = rootURL.lastPathComponent.isEmpty ? "index" : rootURL.lastPathComponent
        panel.nameFieldStringValue = "FolderSize-\(name).fsidx"
        if let ut = UTType(filenameExtension: "fsidx") { panel.allowedContentTypes = [ut] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = index.map(\.event)
        let path = rootURL.standardizedFileURL.path
        let when = Date()
        Task.detached(priority: .userInitiated) {
            try? IndexCache.write(url: url, rootPath: path, savedAt: when, events: snapshot)
        }
    }

    func importIndexPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ut = UTType(filenameExtension: "fsidx") { panel.allowedContentTypes = [ut] }
        if panel.runModal() == .OK, let url = panel.url {
            loadIndex(from: url)
        }
    }

    private func noteLoadFailure() {
        isScanning = false
        errorCount = 1
        lastError = "无法读取索引文件"
    }

    private func tickElapsed() {
        guard isScanning, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
    }

    private func reset(for url: URL) {
        reset(url: url)
    }

    /// 供异步路径在主线程调用的重置
    private func reset(url: URL) {
        let node = Node(url: url, relPath: "")
        root = node
        stack = [node]
        dirty = []
        browseOnly = false
        topFiles = []
        minTopSize = 0
        index = []
        indexCount = 0
        scannedFiles = 0
        scannedBytes = 0
        errorCount = 0
        lastError = nil
        elapsed = 0
        wasCancelled = false
        loadedFromCache = nil
        isScanning = true
        startedAt = Date()

        ticker?.cancel()
        ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.tickElapsed() }
            }
    }

    // MARK: - 增量建树

    /// 利用枚举器的先序保证:事件到达时,除最后一段外的各段目录都已在栈上
    private func apply(_ events: [ScanEvent], generation gen: Int) {
        guard gen == generation, let root else { return }

        var topCandidates: [FileHit] = []
        let minTop = minTopSize

        for event in events {
            // 全量索引
            index.append(FileRecord(
                id: index.count,
                relPath: event.path,
                lowercasedPath: event.path.lowercased(),
                isDirectory: event.isDirectory,
                logical: event.logical,
                allocated: event.allocated
            ))

            let comps = event.path.split(separator: "/")
            guard !comps.isEmpty else { continue }

            // 弹出已离开的目录(栈长 = 当前目录深度 + 1,根始终在栈底)
            while stack.count > comps.count {
                dirty.insert(stack.removeLast())
            }
            guard let parent = stack.last else { continue }

            if event.isDirectory {
                let key = String(comps.last!)
                let child: Node
                if let existing = parent.children[key] {
                    child = existing
                } else {
                    child = Node(
                        url: root.url.appendingPathComponent(event.path),
                        relPath: event.path,
                        parent: parent
                    )
                    parent.children[key] = child
                    parent.dirs += 1
                    dirty.insert(parent)
                }
                stack.append(child)
            } else {
                for ancestor in stack {
                    ancestor.logical += event.logical
                    ancestor.allocated += event.allocated
                    ancestor.files += 1
                    dirty.insert(ancestor)
                }
                scannedFiles += 1
                scannedBytes += event.allocated
                if event.logical > minTop || topFiles.count < 150 {
                    topCandidates.append(FileHit(
                        path: event.path,
                        logical: event.logical,
                        allocated: event.allocated
                    ))
                }
            }
        }
        indexCount = index.count

        if !topCandidates.isEmpty {
            topFiles.append(contentsOf: topCandidates)
            if topFiles.count > 400 {
                topFiles.sort { $0.logical > $1.logical }
                topFiles = Array(topFiles.prefix(150))
                minTopSize = topFiles.last?.logical ?? 0
            }
        }

        resortDirty()
        objectWillChange.send()
    }

    private func finish(
        errorCount errs: Int,
        generation gen: Int,
        cacheDate: Date?,
        scannedRoot: URL?
    ) {
        guard gen == generation else { return }
        isScanning = false
        errorCount = errs
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        topFiles.sort { $0.logical > $1.logical }
        topFiles = Array(topFiles.prefix(150))
        if let cacheDate { loadedFromCache = cacheDate }
        ticker?.cancel()
        ticker = nil
        resortDirty()

        // 完整扫描(未取消)后自动落盘缓存
        if let scannedRoot, !wasCancelled {
            let snapshot = index.map(\.event)
            let path = scannedRoot.standardizedFileURL.path
            let when = Date()
            let url = IndexCache.cacheURL(for: scannedRoot)
            Task.detached(priority: .utility) {
                try? IndexCache.write(url: url, rootPath: path, savedAt: when, events: snapshot)
            }
        }
        objectWillChange.send()
    }

    // MARK: - 排序

    private func resortDirty() {
        guard !dirty.isEmpty else { return }
        let mode = sizeMode
        for node in dirty {
            let newOrder = node.children.values.sorted { $0.size(mode) > $1.size(mode) }
            // 顺序未变时跳过赋值,避免触发 Table 的无谓 diff(减少 NSTableView 重入警告)
            if newOrder.map(\.id) != node.sorted.map(\.id) {
                node.sorted = newOrder
            }
        }
        dirty.removeAll(keepingCapacity: true)
    }

    private func resortAll() {
        guard let root else { return }
        func mark(_ node: Node) {
            dirty.insert(node)
            for child in node.children.values { mark(child) }
        }
        mark(root)
        resortDirty()
        objectWillChange.send()
    }
}
