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

    // MARK: 缓存懒加载(水合)
    //
    // 打开有缓存的目录:先浏览式秒出顶层,后台只做一遍"聚合统计"
    // (目录 → 直接子目录 / 数量 / 聚合大小),把 size/占比注入已显示的节点;
    // 展开时才从聚合索引物化该层的孩子。没点开的子树不建任何 Node。

    /// 一个目录的聚合数据(懒加载缓存索引的一行)
    struct DirIndex {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var totalFiles = 0      // 全部后代文件数(树表"文件"列口径)
        var directFiles = 0     // 直接文件数
        var dirs = 0            // 直接子文件夹数
        var childPaths: [String] = [] // 直接子目录的相对路径
    }

    private var dirIndex: [String: DirIndex]?
    private var hydrating = false

    /// 后台"仅建索引"扫描进行中(不重建可视树,搜索结果随进度实时流入)
    private var backgroundScan = false
    /// 后台扫描攒出的新快照索引(完成时整体替换 index,搜索结果按路径合并到新快照)
    private var freshIndex: [FileRecord] = []

    /// 测试观察:是否仍在水合
    var hydratingForTest: Bool { hydrating }

    /// 聚合:一遍先序扫描建立 目录→聚合 索引 + Top 大文件榜 + 总量。
    /// 纯函数,后台线程调用。
    nonisolated static func aggregate(
        _ events: [ScanEvent]
    ) -> (index: [String: DirIndex], topFiles: [FileHit], totalFiles: Int, totalAllocated: Int64) {
        var index: [String: DirIndex] = ["": DirIndex()]
        // 先序保证:文件/目录事件到达时其祖先链都在栈上(栈底为根)
        var stack: [(key: String, depth: Int)] = [("", 0)]
        var topFiles: [FileHit] = []
        var minTop: Int64 = 0
        var totalFiles = 0
        var totalAllocated: Int64 = 0

        for ev in events {
            let depth = ev.path.split(separator: "/").count
            // 目录和文件都要先弹栈:先序中父目录没有"关闭"事件,
            // 下一个更浅深度的事件意味着它已结束(如目录后的顶层文件)
            while stack.last!.depth >= depth { stack.removeLast() }
            if ev.isDirectory {
                let parent = stack.last!.key
                index[parent, default: DirIndex()].dirs += 1
                index[parent, default: DirIndex()].childPaths.append(ev.path)
                if index[ev.path] == nil { index[ev.path] = DirIndex() }
                stack.append((ev.path, depth))
            } else {
                totalFiles += 1
                totalAllocated += ev.allocated
                for ancestor in stack {
                    index[ancestor.key, default: DirIndex()].logical += ev.logical
                    index[ancestor.key, default: DirIndex()].allocated += ev.allocated
                    index[ancestor.key, default: DirIndex()].totalFiles += 1
                }
                index[stack.last!.key, default: DirIndex()].directFiles += 1
                if ev.logical > minTop || topFiles.count < 150 {
                    topFiles.append(FileHit(
                        path: ev.path, logical: ev.logical, allocated: ev.allocated))
                    if topFiles.count > 400 {
                        topFiles.sort { $0.logical > $1.logical }
                        topFiles = Array(topFiles.prefix(150))
                        minTop = topFiles.last?.logical ?? 0
                    }
                }
            }
        }
        return (index, topFiles, totalFiles, totalAllocated)
    }

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

    /// 智能打开:有缓存 → 浏览式秒出顶层,后台聚合注入 size/占比(懒加载水合);
    /// 无缓存 → 浏览模式。所有常规打开入口走这里。
    func openSmart(at url: URL) {
        openForBrowse(at: url)
        if IndexCache.exists(for: url) {
            hydrateFromCache(at: url)
        }
    }

    /// 后台解析缓存并聚合(不建树!只建 目录→聚合 索引),完成后把
    /// size/占比注入已显示的顶层节点,并备好按需物化的聚合索引。
    private func hydrateFromCache(at url: URL) {
        hydrating = true
        let cacheURL = IndexCache.cacheURL(for: url)
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let cached = IndexCache.read(url: cacheURL) else {
                await self?.hydrateFailed(gen: gen)
                return
            }
            let agg = ScanStore.aggregate(cached.events)
            let records = cached.events.enumerated().map { i, ev in
                FileRecord(
                    id: i,
                    relPath: ev.path,
                    lowercasedPath: ev.path.lowercased(),
                    isDirectory: ev.isDirectory,
                    logical: ev.logical,
                    allocated: ev.allocated
                )
            }
            await self?.installHydration(
                agg, records: records, savedAt: cached.savedAt, url: url, gen: gen)
        }
    }

    private func hydrateFailed(gen: Int) {
        guard gen == generation else { return }
        hydrating = false // 解析失败:停留在浏览模式,用户可点「统计大小」真扫
        objectWillChange.send()
    }

    @MainActor
    private func installHydration(
        _ agg: (index: [String: DirIndex], topFiles: [FileHit], totalFiles: Int, totalAllocated: Int64),
        records: [FileRecord],
        savedAt: Date,
        url: URL,
        gen: Int
    ) {
        guard gen == generation, hydrating, let root,
              root.url.standardizedFileURL.path == url.standardizedFileURL.path else { return }
        hydrating = false
        injectAggregation(agg, savedAt: savedAt, rootURL: url)
        index = records
        indexCount = records.count
        objectWillChange.send()
    }

    /// 把聚合结果注入**当前已显示的浏览树**(不重建):
    /// 已 readdir 物化的层级 → 原地更新大小并按大小重排(保留节点身份/展开状态);
    /// 未物化的层级 → 保持 pending,展开时从 dirIndex 物化。
    @MainActor
    private func injectAggregation(
        _ agg: (index: [String: DirIndex], topFiles: [FileHit], totalFiles: Int, totalAllocated: Int64),
        savedAt: Date?,
        rootURL: URL
    ) {
        guard let root,
              root.url.standardizedFileURL.path == rootURL.standardizedFileURL.path else { return }
        dirIndex = agg.index

        func inject(_ node: Node) {
            guard let di = agg.index[node.relPath] else { return }
            node.logical = di.logical
            node.allocated = di.allocated
            node.files = di.totalFiles
            node.dirs = di.dirs
            // 只有已 readdir 物化的节点(children 非空)才清 pending 并递归注入孩子;
            // 未物化的保持 pending,展开时从聚合索引物化(保持节点身份/展开状态)
            guard !node.children.isEmpty else { return }
            node.browsePending = false
            var dirKids: [Node] = []
            for child in node.sorted where !child.isFile {
                guard agg.index[child.relPath] != nil else { continue } // 磁盘有但缓存无(扫描后新建)→ 统计视图不显示
                inject(child)
                dirKids.append(child)
            }
            node.sorted = dirKids.sorted { $0.size(sizeMode) > $1.size(sizeMode) }
        }
        inject(root)

        topFiles = agg.topFiles
        scannedFiles = agg.totalFiles
        scannedBytes = agg.totalAllocated
        loadedFromCache = savedAt
        browseOnly = false
        errorCount = 0
        lastError = nil
        objectWillChange.send()
    }

    /// 统计懒加载:展开目录时从聚合索引物化该层的孩子(无 IO,微秒级)。
    /// 未展开的子树不建任何 Node。由 NSOutlineView 数据源在展开/绘制时调用。
    func materializeLazyIfNeeded(_ node: Node) {
        guard !browseOnly, !hydrating, node.browsePending,
              let index = dirIndex, let di = index[node.relPath] else { return }
        node.browsePending = false
        node.dirs = di.dirs
        node.files = di.totalFiles
        var kids: [Node] = []
        for childPath in di.childPaths {
            guard let ci = index[childPath] else { continue }
            let name = (childPath as NSString).lastPathComponent
            let child = Node(url: node.url.appendingPathComponent(name), relPath: childPath, parent: node)
            child.logical = ci.logical
            child.allocated = ci.allocated
            child.files = ci.totalFiles
            child.dirs = ci.dirs
            child.browsePending = true
            node.children[name] = child
            kids.append(child)
        }
        node.sorted = kids.sorted { $0.size(sizeMode) > $1.size(sizeMode) }
    }

    /// 输入搜索词时调用:cache1 命中立即显示(已在内存),同时后台扫描刷新,
    /// 完成后原子重建缓存并整体切换搜索索引(按路径合并到新快照)。
    /// cache 新鲜(60s 内)则跳过,避免重复大扫描。
    func startSearchDrivenIndexScanIfNeeded() {
        guard let url = root?.url else { return }
        guard !isScanning, !hydrating, !backgroundScan else { return }
        if let mtime = IndexCache.modificationDate(for: url),
           Date().timeIntervalSince(mtime) < 60 { return }
        startBackgroundIndexScan(at: url)
    }

    /// 后台"仅建索引"扫描:不动可视树(用户继续浏览),攒事件流供
    /// ① 搜索索引逐批可见 ② 完成后原子重建缓存 ③ 聚合注入大小。
    func startBackgroundIndexScan(at url: URL) {
        scanTask?.cancel()
        generation += 1
        let gen = generation
        backgroundScan = true
        isScanning = true
        wasCancelled = false
        startedAt = Date()
        elapsed = 0
        topFiles = []
        freshIndex = []
        scannedFiles = 0
        scannedBytes = 0
        errorCount = 0
        lastError = nil
        loadedFromCache = nil
        ticker?.cancel()
        ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.tickElapsed() }
            }

        let hidden = includeHidden
        let cacheURL = IndexCache.cacheURL(for: url)
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let errors = await DirectoryScanner.scan(root: url, includeHidden: hidden) { [weak self] batch in
                await self?.applyIndexBatch(batch, generation: gen)
            }
            await self?.finishBackgroundIndexScan(
                errorCount: errors, generation: gen, rootURL: url, cacheURL: cacheURL)
        }
    }

    private func applyIndexBatch(_ batch: [ScanEvent], generation gen: Int) {
        guard gen == generation, backgroundScan else { return }
        var nextID = freshIndex.count
        for ev in batch {
            freshIndex.append(FileRecord(
                id: nextID,
                relPath: ev.path,
                lowercasedPath: ev.path.lowercased(),
                isDirectory: ev.isDirectory,
                logical: ev.logical,
                allocated: ev.allocated
            ))
            nextID += 1
            if !ev.isDirectory {
                scannedFiles += 1
                scannedBytes += ev.allocated
            }
        }
        objectWillChange.send() // 状态栏进度;indexCount 未变,当前搜索结果保持稳定
    }

    private func finishBackgroundIndexScan(
        errorCount errs: Int,
        generation gen: Int,
        rootURL url: URL,
        cacheURL: URL
    ) {
        guard gen == generation, backgroundScan else { return }
        isScanning = false
        backgroundScan = false
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        errorCount = errs
        ticker?.cancel()
        ticker = nil

        // 搜索索引整体切换到新快照 → onChange(indexCount) 用同一关键词重跑,
        // 结果按路径合并呈现(新增出现/已删消失/同名取新大小)
        index = freshIndex
        indexCount = freshIndex.count
        freshIndex = []
        let events = index.map {
            ScanEvent(path: $0.relPath, isDirectory: $0.isDirectory,
                      logical: $0.logical, allocated: $0.allocated)
        }
        let agg = ScanStore.aggregate(events)

        // 原子重建缓存(后台线程):整份快照替换,不做增量合并
        let savedAt = Date()
        let rootPath = url.standardizedFileURL.path
        Task.detached(priority: .utility) {
            try? IndexCache.write(url: cacheURL, rootPath: rootPath, savedAt: savedAt, events: events)
        }

        injectAggregation(agg, savedAt: nil, rootURL: url) // savedAt=nil:数据是刚扫的,非缓存
        topFiles.sort { $0.logical > $1.logical }
        topFiles = Array(topFiles.prefix(150))
        objectWillChange.send()
    }

    /// 浏览模式:只列出 url 的顶层子文件夹(同步、秒开),不统计大小。
    /// 所有"打开目录"的入口(侧栏 / 收藏夹 / 拖拽 / --path)默认走这里,
    /// 需要大小数据时再点「统计大小」或 ⌘R 进入统计。
    func openForBrowse(at url: URL) {
        scanTask?.cancel()
        generation += 1
        backgroundScan = false
        freshIndex = []

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
        guard browseOnly, !hydrating, node.browsePending else { return } // 水合期间不 readdir,等聚合注入
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
        backgroundScan = false
        freshIndex = []
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
