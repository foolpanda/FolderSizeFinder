import XCTest
import SwiftUI
import AppKit
@testable import FolderSize

final class FolderSizeTests: XCTestCase {
    private var rootURL: URL!

    /// 测试夹具:
    /// ├── a/            f1.bin 5,000,000 + f2.bin 3,000,000
    /// │   └── b/        f3.bin 1,000,000
    /// ├── .hidden       500,000
    /// └── root.txt      100,000
    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fstest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rootURL = dir
        try makeFile("a/f1.bin", 5_000_000)
        try makeFile("a/f2.bin", 3_000_000)
        try makeFile("a/b/f3.bin", 1_000_000)
        try makeFile(".hidden", 500_000)
        try makeFile("root.txt", 100_000)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: IndexCache.cacheURL(for: rootURL)) // 清掉自动缓存
    }

    private func makeFile(_ rel: String, _ size: Int) throws {
        let url = rootURL.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: size).write(to: url)
    }

    /// 等待扫描结束
    @MainActor
    private func waitUntilDone(_ store: ScanStore, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isScanning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(store.isScanning, "扫描超时")
    }

    @MainActor
    private func waitUntilCacheExists(timeout: TimeInterval = 5) async throws {
        let url = IndexCache.cacheURL(for: rootURL)
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缓存文件未生成")
    }

    // MARK: - 扫描管线

    @MainActor
    func testFullPipelineAggregation() async throws {
        let store = ScanStore()
        store.startScan(at: rootURL)
        try await waitUntilDone(store)

        let root = try XCTUnwrap(store.root)
        XCTAssertEqual(root.files, 5, "根目录文件总数")
        XCTAssertEqual(root.dirs, 1, "直接子目录数(仅 a;a/b 计入 a)")
        XCTAssertEqual(root.logical, 9_600_000, "根目录逻辑大小合计")

        let a = try XCTUnwrap(root.children["a"])
        XCTAssertEqual(a.logical, 9_000_000, "a 目录合计")
        XCTAssertEqual(a.files, 3)
        XCTAssertEqual(a.children["b"]?.logical, 1_000_000, "深层目录冒泡")

        XCTAssertEqual(root.sorted.first?.name, "a", "按大小降序")
        XCTAssertEqual(store.topFiles.first?.name, "f1.bin", "最大文件榜首")
        XCTAssertEqual(store.errorCount, 0)

        XCTAssertEqual(store.indexCount, 7, "全量索引:5 文件 + 2 目录")
        XCTAssertEqual(store.index.filter(\.isDirectory).count, 2)
    }

    @MainActor
    func testHiddenFilesExcluded() async throws {
        let store = ScanStore()
        store.includeHidden = false // 根未设置时不会触发重扫
        store.startScan(at: rootURL, preferCache: false)
        try await waitUntilDone(store)

        XCTAssertEqual(store.root?.files, 4, "应跳过 .hidden")
        XCTAssertEqual(store.root?.logical, 9_100_000)
    }

    @MainActor
    func testRescanReplacesTree() async throws {
        let store = ScanStore()
        store.startScan(at: rootURL)
        try await waitUntilDone(store)
        XCTAssertEqual(store.root?.files, 5)

        try makeFile("extra.bin", 2_000_000)
        store.startScan(at: rootURL, preferCache: false) // 强制重扫
        try await waitUntilDone(store)
        XCTAssertEqual(store.root?.files, 6, "重扫后应反映新增文件")
        XCTAssertEqual(store.root?.logical, 11_600_000)
    }

    // MARK: - 索引缓存

    func testIndexCacheRoundTrip() throws {
        let events = [
            ScanEvent(path: "a", isDirectory: true, logical: 0, allocated: 0),
            ScanEvent(path: "a/f1.bin", isDirectory: false, logical: 5_000_000, allocated: 5_048_320),
            ScanEvent(path: "a/子目录/文件 2.bin", isDirectory: false, logical: 123, allocated: 128),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString).fsidx")
        defer { try? FileManager.default.removeItem(at: url) }

        let savedAt = Date()
        try IndexCache.write(url: url, rootPath: "/tmp/某目录", savedAt: savedAt, events: events)
        let loaded = try XCTUnwrap(IndexCache.read(url: url))

        XCTAssertEqual(loaded.rootPath, "/tmp/某目录", "中文路径往返")
        XCTAssertEqual(loaded.events.count, events.count)
        XCTAssertEqual(loaded.savedAt.timeIntervalSince(savedAt), 0, accuracy: 0.001)
        for (a, b) in zip(events, loaded.events) {
            XCTAssertEqual(a.path, b.path)
            XCTAssertEqual(a.isDirectory, b.isDirectory)
            XCTAssertEqual(a.logical, b.logical)
            XCTAssertEqual(a.allocated, b.allocated)
        }
    }

    func testIndexCacheRejectsGarbage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).fsidx")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("这不是索引文件".utf8).write(to: url)
        XCTAssertNil(IndexCache.read(url: url))
    }

    @MainActor
    func testScanAutoSavesCacheAndReloads() async throws {
        // 第一次扫描 → 自动落盘
        let first = ScanStore()
        first.startScan(at: rootURL)
        try await waitUntilDone(first)
        try await waitUntilCacheExists()

        // 第二个实例、同一目录:应秒载缓存,不实际扫描
        let second = ScanStore()
        second.startScan(at: rootURL, preferCache: true)
        try await waitUntilDone(second)

        XCTAssertNotNil(second.loadedFromCache, "应标记为缓存载入")
        XCTAssertEqual(second.root?.files, 5)
        XCTAssertEqual(second.root?.logical, 9_600_000)
        XCTAssertEqual(second.indexCount, 7, "索引经缓存完整重建")
        XCTAssertEqual(second.root?.sorted.first?.name, "a", "排序也经重放恢复")
        XCTAssertEqual(second.errorCount, 0)
    }

    // MARK: - 搜索过滤

    private func rec(_ rel: String, _ size: Int64, dir: Bool = false) -> FileRecord {
        FileRecord(
            id: rel, relPath: rel, lowercasedPath: rel.lowercased(),
            isDirectory: dir, logical: size, allocated: size
        )
    }

    func testSearchFilterBasics() {
        let records = [
            rec("a/b/x.txt", 100),
            rec("a/bee.jpg", 50),
            rec("c/x.txt", 200),
            rec("a", 0, dir: true),
        ]
        // 单关键词
        var out = SearchFilter.filter(records: records, prefix: "", query: "x.txt", cap: 100, key: .name, descending: false)
        XCTAssertEqual(out.total, 2)
        // 多关键词 AND
        out = SearchFilter.filter(records: records, prefix: "", query: "a x", cap: 100, key: .name, descending: false)
        XCTAssertEqual(out.total, 1)
        XCTAssertEqual(out.items.first?.relPath, "a/b/x.txt")
        // 范围限定:prefix "a" 覆盖 a 自身与子树,但按 query 过滤
        out = SearchFilter.filter(records: records, prefix: "a", query: "x", cap: 100, key: .name, descending: false)
        XCTAssertEqual(out.total, 1)
        XCTAssertEqual(out.items.first?.relPath, "a/b/x.txt")
        // 前缀不误伤:a 不匹配 "ab/..."
        let tricky = [rec("ab/x", 1), rec("a/y", 1)]
        out = SearchFilter.filter(records: tricky, prefix: "a", query: "", cap: 100, key: .path, descending: false)
        XCTAssertEqual(out.total, 1)
        // 大小写不敏感
        out = SearchFilter.filter(records: records, prefix: "", query: "X.TXT", cap: 100, key: .name, descending: false)
        XCTAssertEqual(out.total, 2)
    }

    @MainActor
    func testQuickLookExpandsSiblingImages() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.png", "a.png", "c.txt", "d.jpg"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let selected = dir.appendingPathComponent("b.png")
        let (list, start) = FileActions.quickLookList(for: [selected])
        XCTAssertEqual(list.map(\.lastPathComponent), ["a.png", "b.png", "d.jpg"], "同目录图片全部入列")
        XCTAssertEqual(start, 1, "从选中图片开始预览")
        XCTAssertEqual(list[start].lastPathComponent, "b.png")

        // 非图片不扩展
        let (single, s0) = FileActions.quickLookList(for: [dir.appendingPathComponent("c.txt")])
        XCTAssertEqual(single.map(\.lastPathComponent), ["c.txt"])
        XCTAssertEqual(s0, 0)
    }

    func testImageFolderEnumeration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.png", "A.JPG", "c.jpeg", "d.heic", "note.txt", ".hidden.png", "noext"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        for name in ["sub2", "sub1", ".hiddendir"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }

        let images = ImageFolder.images(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(images, ["A.JPG", "b.png", "c.jpeg", "d.heic"],
                       "只取图片、自然排序、跳过隐藏文件")

        let subs = ImageFolder.subdirectories(of: dir).map(\.lastPathComponent)
        XCTAssertEqual(subs, ["sub1", "sub2"], "只取目录、自然排序、跳过隐藏目录")
    }

    @MainActor
    func testMenuShowsImagePreviewOnlyForImages() {
        let defaults = UserDefaults(suiteName: "menutest-\(UUID().uuidString)")!
        let launchers = LauncherStore(defaults: defaults)
        var opened: [String] = []
        let openPreview: (URL) -> Void = { opened.append($0.path) }

        let image = FileItem(url: URL(fileURLWithPath: "/tmp/x/photo.png"), isDirectory: false)
        let text = FileItem(url: URL(fileURLWithPath: "/tmp/x/note.txt"), isDirectory: false)

        let imageEntries = FileMenuFactory.menuEntries(items: [image], launchers: launchers,
                                                       openImagePreview: openPreview)
        XCTAssertTrue(collectTitles(imageEntries).contains(L.t("file.imagePreview")),
                      "图片应出现「图片预览…」")

        // 触发回调,确认传出的是该图片路径
        if let entry = imageEntries.first(where: { $0.title == L.t("file.imagePreview") }),
           case .action(let handler) = entry.kind {
            handler()
        }
        XCTAssertEqual(opened, ["/tmp/x/photo.png"])

        let textEntries = FileMenuFactory.menuEntries(items: [text], launchers: launchers,
                                                      openImagePreview: openPreview)
        XCTAssertFalse(collectTitles(textEntries).contains(L.t("file.imagePreview")),
                       "非图片不应出现")

        let noOpener = FileMenuFactory.menuEntries(items: [image], launchers: launchers)
        XCTAssertFalse(collectTitles(noOpener).contains(L.t("file.imagePreview")),
                       "未提供回调时不应出现")
    }

    private func collectTitles(_ entries: [FileMenuEntry]) -> [String] {
        entries.flatMap { entry -> [String] in
            switch entry.kind {
            case .submenu(let subs): return [entry.title] + collectTitles(subs)
            default: return [entry.title]
            }
        }
    }

    // MARK: - 真实 AppKit 渲染层(无需辅助功能权限)

    @MainActor
    func testFileMenuEntryRendersNSMenuItem() {
        // 普通 action → NSMenuItem,并能触发闭包
        var fired = 0
        let item = FileMenuEntry.action("图片预览…", icon: "photo") { fired += 1 }.nsMenuItem
        XCTAssertEqual(item.title, "图片预览…")
        XCTAssertTrue(item.isEnabled)
        XCTAssertNotNil(item.image)
        (item.representedObject as? MenuActionBox)?.run(item)
        XCTAssertEqual(fired, 1, "NSMenuItem 点击应触发 handler")

        // 子菜单 action / separator / action
        let sub = FileMenuEntry.submenu("比较", entries: [
            .action("Beyond Compare") {},
            .separator(),
            .action("FileMerge") {},
        ]).nsMenuItem
        XCTAssertEqual(sub.submenu?.items.count, 3)
        XCTAssertEqual(sub.submenu?.items[1].isSeparatorItem, true)
    }

    @MainActor
    func testQuickLookItemCarriesCountTitle() {
        let raw = QuickLookItem(url: URL(fileURLWithPath: "/tmp/a.png"),
                                title: L.f("quicklook.title", "a.png", 2, 5))
        XCTAssertEqual(raw.previewItemTitle, "a.png (2/5)")
        XCTAssertEqual(raw.previewItemURL?.lastPathComponent, "a.png")
    }

    @MainActor
    func testImagePreviewWindowBuildsAndScopeCodable() throws {
        let scope = ImagePreviewScope(filePath: "/tmp/nonexistent/photo.png")
        let back = try JSONDecoder().decode(ImagePreviewScope.self,
                                           from: try JSONEncoder().encode(scope))
        XCTAssertEqual(back, scope)

        // 真正构建 SwiftUI 视图并布局,确保窗口内容不崩溃
        let host = NSHostingView(rootView: ImagePreviewWindow(scope: scope))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    @MainActor
    func testTreeMenuContainsCoreItems() {
        let defaults = UserDefaults(suiteName: "treemenu-\(UUID().uuidString)")!
        let store = ScanStore()
        let favorites = FavoritesStore(defaults: defaults)
        let launchers = LauncherStore(defaults: defaults)

        // 文件夹节点:应包含打开/打开方式/属性/在访达中显示/终端/拷贝路径/废纸篓 + 文件夹专属项
        let folder = Node(url: URL(fileURLWithPath: "/tmp/x/dir"), relPath: "dir")
        let folderTitles = collectTitles(FileMenuFactory.treeEntries(
            nodes: [folder], primary: folder, store: store,
            favorites: favorites, launchers: launchers, openSearch: {}))
        for key in ["file.open", "file.openWith", "file.properties", "file.getInfo",
                    "file.copyPath", "file.copy", "file.trash",
                    "tree.reveal", "tree.openTerminal", "tree.search", "tree.enter"] {
            XCTAssertTrue(folderTitles.contains(L.t(key)), "文件夹菜单缺少 \(key)")
        }

        // 图片文件节点:有快速查看 + 图片预览,且不含文件夹专属项,不应有比较(仅单选非两项)
        let file = Node(url: URL(fileURLWithPath: "/tmp/x/pic.png"), relPath: "pic.png")
        file.isFile = true
        var opened: URL?
        let fileTitles = collectTitles(FileMenuFactory.treeEntries(
            nodes: [file], primary: file, store: store,
            favorites: favorites, launchers: launchers, openSearch: {},
            openImagePreview: { opened = $0 }))
        XCTAssertTrue(fileTitles.contains(L.t("file.quickLook")))
        XCTAssertTrue(fileTitles.contains(L.t("file.imagePreview")))
        XCTAssertFalse(fileTitles.contains(L.t("tree.search")), "文件不应有文件夹专属项")
        XCTAssertNil(opened, "仅构建菜单不应触发打开预览")
    }

    func testSearchFilterSortAndCap() {
        let records = [
            rec("b.txt", 10),
            rec("a.txt", 30),
            rec("c.txt", 20),
        ]
        // 大小降序
        var out = SearchFilter.filter(records: records, prefix: "", query: "txt", cap: 100, key: .size, descending: true)
        XCTAssertEqual(out.items.map(\.name), ["a.txt", "c.txt", "b.txt"])
        // 名称升序
        out = SearchFilter.filter(records: records, prefix: "", query: "txt", cap: 100, key: .name, descending: false)
        XCTAssertEqual(out.items.map(\.name), ["a.txt", "b.txt", "c.txt"])
        // cap 只影响展示,不影响命中总数
        out = SearchFilter.filter(records: records, prefix: "", query: "txt", cap: 2, key: .name, descending: false)
        XCTAssertEqual(out.total, 3)
        XCTAssertEqual(out.items.count, 2)
        XCTAssertEqual(out.items.map(\.name), ["a.txt", "b.txt"], "cap 前应已排序")
    }

    // MARK: - 查询语法

    func testQueryParserTokens() {
        let p = QueryParser.parse("报告 2024 *.pdf ext:LOG size:>100mb size:<1gb folder:node file:cat*")
        // file:cat* 先命中 file: 分支,余下 cat* 作为普通词
        XCTAssertEqual(p.terms, ["报告", "2024", "node", "cat*"])
        XCTAssertTrue(p.foldersOnly)
        XCTAssertTrue(p.filesOnly)
        XCTAssertEqual(p.nameGlobs, ["*.pdf"])
        XCTAssertEqual(p.extensions, ["log"])
        XCTAssertEqual(p.minSize, 100 * 1024 * 1024)
        XCTAssertEqual(p.maxSize, 1024 * 1024 * 1024)
    }

    func testQueryParserSizeUnits() {
        func size(_ s: String) -> Int64? {
            QueryParser.parseSize(s[...])
        }
        XCTAssertEqual(size("100"), 100)
        XCTAssertEqual(size("2kb"), 2048)
        XCTAssertEqual(size("1.5mb"), 1_572_864)
        XCTAssertEqual(size("1gb"), 1_073_741_824)
        XCTAssertEqual(size("2t"), 2_199_023_255_552)
        XCTAssertEqual(size("512K".lowercased()), 524_288)
        XCTAssertNil(size(""), "空串")
        XCTAssertNil(size("mb"), "无数字")
        XCTAssertNil(size("10zb"), "未知单位")
        XCTAssertNil(size("-5mb"), "负数")
    }

    func testQueryParserEmptyAndSameSyntaxTwice() {
        XCTAssertEqual(QueryParser.parse(""), ParsedQuery())
        XCTAssertTrue(QueryParser.parse("   ").isEmpty)
        // 同一语法写两次:区间可来自两段,大于取后者
        let p = QueryParser.parse("size:>10mb size:>20mb")
        XCTAssertEqual(p.minSize, 20 * 1024 * 1024)
    }

    func testSearchFilterSyntax() {
        let records = [
            rec("docs/报告 2024.pdf", 5_000_000),
            rec("logs/app.log", 200_000_000),
            rec("logs/old.txt", 50),
            rec("img/cat.png", 1_000),
            rec("node_modules", 0, dir: true),
            rec("src", 0, dir: true),
        ]
        func hits(_ q: String) -> [String] {
            SearchFilter.filter(records: records, prefix: "", query: q, cap: 100, key: .path, descending: false)
                .items.map(\.relPath)
        }

        XCTAssertEqual(hits("*.pdf"), ["docs/报告 2024.pdf"], "通配符匹配名称")
        XCTAssertEqual(hits("c?t.png"), ["img/cat.png"], "? 通配单个字符")
        XCTAssertEqual(hits("ext:log"), ["logs/app.log"], "扩展名")
        XCTAssertEqual(hits("ext:pdf 报告"), ["docs/报告 2024.pdf"], "扩展名 + 关键词组合")
        XCTAssertEqual(hits("size:>100mb"), ["logs/app.log"], "大小下限")
        XCTAssertEqual(hits("size:<1000 file:"), ["img/cat.png", "logs/old.txt"], "大小上限(排除大小为 0 的目录记录)")
        XCTAssertEqual(hits("size:>1kb size:<10mb"), ["docs/报告 2024.pdf"], "大小区间")
        XCTAssertEqual(Set(hits("folder:")), ["node_modules", "src"], "只看文件夹")
        XCTAssertEqual(hits("folder:node"), ["node_modules"], "带关键词的文件夹过滤")
        XCTAssertEqual(hits("file:app"), ["logs/app.log"], "只看文件")
    }
}
