import XCTest
@testable import FolderSize

@MainActor
final class BrowseModeTests: XCTestCase {
    private var rootURL: URL!

    /// 测试夹具:
    /// ├── a/            (含子目录 sub/)
    /// ├── b/            (空)
    /// ├── .hiddendir/
    /// └── f.txt
    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsbrowse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rootURL = dir
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".hiddendir"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testBrowseListsTopFoldersOnly() {
        let store = ScanStore()
        store.openForBrowse(at: rootURL)

        XCTAssertTrue(store.browseOnly)
        XCTAssertFalse(store.isScanning)
        XCTAssertNil(store.loadedFromCache)

        let names = store.root?.sorted.map(\.name)
        // 文件夹在前(自然序),文件跟随;文件也列出且带自身大小
        XCTAssertEqual(names, [".hiddendir", "a", "b", "f.txt"])
        XCTAssertEqual(store.root?.sorted.first?.relPath, ".hiddendir") // 顶层 relPath = 目录名
        XCTAssertEqual(store.root?.sorted.first { $0.name == "a" }?.url.lastPathComponent, "a")
        // 根的直接数量已就绪;子目录未列出前数量为 0、标记 pending
        XCTAssertEqual(store.root?.dirs, 3)
        XCTAssertEqual(store.root?.files, 1) // f.txt
        XCTAssertEqual(store.root?.sorted.first?.dirs, 0)
        XCTAssertTrue(store.root!.sorted.filter { !$0.isFile }.allSatisfy(\.browsePending))
        // 浏览模式:文件夹无大小数据;文件行带自身大小
        XCTAssertTrue(store.root!.sorted.filter { !$0.isFile }
            .allSatisfy { $0.size(.allocated) == 0 && $0.size(.logical) == 0 })
        XCTAssertEqual(store.root?.sorted.first { $0.name == "f.txt" }?.logical, 1) // "x" = 1 字节
        XCTAssertEqual(store.indexCount, 0)
    }

    func testLazyExpandFillsChildrenAndCounts() {
        let store = ScanStore()
        store.openForBrowse(at: rootURL)
        let a = store.root!.sorted.first { $0.name == "a" }!
        XCTAssertTrue(a.browsePending)

        store.browseListIfNeeded(a) // 同步懒加载(大纲视图绘制/展开行时调用)

        XCTAssertFalse(a.browsePending)
        XCTAssertEqual(a.sorted.map(\.name), ["sub"])
        XCTAssertEqual(a.sorted.first?.relPath, "a/sub") // 深层 relPath 带父路径
        XCTAssertEqual(a.dirs, 1)  // 直接子文件夹数
        XCTAssertEqual(a.files, 0) // a 下没有直接文件
        XCTAssertEqual(a.sorted.first?.browsePending, true)

        // 已列出的空目录:数量为 0,不可展开
        let b = store.root!.sorted.first { $0.name == "b" }!
        store.browseListIfNeeded(b)
        XCTAssertFalse(b.browsePending)
        XCTAssertTrue(b.sorted.isEmpty)
        XCTAssertEqual(b.dirs, 0)
        XCTAssertEqual(b.files, 0)
    }

    func testBrowseRespectsHiddenToggle() {
        let store = ScanStore()
        store.includeHidden = true
        store.openForBrowse(at: rootURL)
        XCTAssertEqual(store.root?.sorted.count, 4) // 3 目录 + f.txt

        store.includeHidden = false // 浏览模式下只重新列目录,不触发扫描
        XCTAssertTrue(store.browseOnly)
        XCTAssertFalse(store.isScanning)
        XCTAssertEqual(store.root?.sorted.map(\.name), ["a", "b", "f.txt"])
    }

    func testStartScanExitsBrowseMode() {
        let store = ScanStore()
        store.openForBrowse(at: rootURL)
        XCTAssertTrue(store.browseOnly)

        store.startScan(at: rootURL, preferCache: false)
        XCTAssertFalse(store.browseOnly)
        XCTAssertTrue(store.isScanning)
        store.cancelScan()
    }

    func testEnterSubFolderBrowsesDeeper() {
        let store = ScanStore()
        store.openForBrowse(at: rootURL)
        let a = store.root?.sorted.first { $0.name == "a" }
        store.openForBrowse(at: a!.url)

        XCTAssertTrue(store.browseOnly)
        XCTAssertEqual(store.root?.sorted.map(\.name), ["sub"])
        XCTAssertEqual(store.root?.url.lastPathComponent, "a")
    }
}
