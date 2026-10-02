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
        XCTAssertEqual(names, [".hiddendir", "a", "b"]) // 目录名自然序(点开头在前),文件不列
        XCTAssertEqual(store.root?.sorted.first?.relPath, ".hiddendir") // 顶层 relPath = 目录名
        XCTAssertEqual(store.root?.sorted.first { $0.name == "a" }?.url.lastPathComponent, "a")
        // 浏览模式没有大小数据
        XCTAssertTrue(store.root!.sorted.allSatisfy { $0.size(.allocated) == 0 && $0.size(.logical) == 0 })
        XCTAssertEqual(store.indexCount, 0)
    }

    func testBrowseRespectsHiddenToggle() {
        let store = ScanStore()
        store.includeHidden = true
        store.openForBrowse(at: rootURL)
        XCTAssertEqual(store.root?.sorted.count, 3)

        store.includeHidden = false // 浏览模式下只重新列目录,不触发扫描
        XCTAssertTrue(store.browseOnly)
        XCTAssertFalse(store.isScanning)
        XCTAssertEqual(store.root?.sorted.map(\.name), ["a", "b"])
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
