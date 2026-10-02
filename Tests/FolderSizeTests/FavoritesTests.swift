import XCTest
@testable import FolderSize

@MainActor
final class FavoritesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: FavoritesStore!

    override func setUp() {
        suiteName = "FavoritesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = FavoritesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: 工具

    private func cat(_ name: String) -> FavoriteNode { .category(name) }
    private func folder(_ name: String, _ path: String) -> FavoriteNode { .folder(name, path) }

    // MARK: 用例

    func testAddFolderTopLevelAndDuplicateRejected() {
        XCTAssertTrue(store.addFolder(name: "工作", path: "/tmp/work", into: nil))
        XCTAssertEqual(store.roots.count, 1)
        XCTAssertEqual(store.roots[0].name, "工作")
        XCTAssertFalse(store.roots[0].isCategory)

        // 同层重复路径拒绝
        XCTAssertFalse(store.addFolder(name: "别的名字", path: "/tmp/work", into: nil))
        XCTAssertEqual(store.roots.count, 1)
    }

    func testAddIntoCategoryAndMissingParentFails() {
        let id = store.addCategory(named: "视频")!
        XCTAssertTrue(store.addFolder(name: "素材", path: "/tmp/media", into: id))
        XCTAssertEqual(store.roots.count, 1)
        XCTAssertEqual(store.roots[0].children.first?.path, "/tmp/media")

        // 父节点不存在 → 失败,目录收藏不能挂在目录收藏下面
        XCTAssertFalse(store.addFolder(name: "X", path: "/tmp/x", into: UUID()))
    }

    func testNestedCategoriesAndFlatten() {
        let work = store.addCategory(named: "工作")!
        let video = store.addCategory(named: "视频", into: work)!
        store.addFolder(name: "脚本", path: "/tmp/scripts", into: video)

        let flat = store.categories()
        XCTAssertEqual(flat.map(\.title), ["工作", "工作 / 视频"])
        XCTAssertTrue(FavoritesStore.contains(id: video, in: store.roots))
    }

    func testRename() {
        let id = store.addCategory(named: "旧名")!
        XCTAssertTrue(store.rename(id: id, to: "  新名  ")) // 会 trim
        XCTAssertEqual(store.roots[0].name, "新名")
        XCTAssertFalse(store.rename(id: id, to: "   ")) // 空白拒绝
        XCTAssertFalse(store.rename(id: UUID(), to: "无所谓"))
    }

    func testRemoveCategoryRemovesSubtree() {
        let work = store.addCategory(named: "工作")!
        store.addCategory(named: "子分类", into: work)
        store.addFolder(name: "A", path: "/tmp/a", into: work)

        XCTAssertTrue(store.remove(id: work))
        XCTAssertTrue(store.roots.isEmpty)
        XCTAssertFalse(store.remove(id: work)) // 再删一次失败
    }

    func testMoveGuards() {
        let work = store.addCategory(named: "工作")!
        let video = store.addCategory(named: "视频", into: work)!
        let inner = store.addCategory(named: "内层", into: video)!
        store.addFolder(name: "A", path: "/tmp/a", into: nil)
        let topA = store.roots.first { $0.path == "/tmp/a" }!.id

        // 分类移进自己 / 自己的子孙 → 拒绝(防环)
        XCTAssertFalse(store.move(id: work, into: video))
        XCTAssertFalse(store.move(id: work, into: inner))
        XCTAssertEqual(store.categories().map(\.title), ["工作", "工作 / 视频", "工作 / 视频 / 内层"])

        // 顶层目录收藏移进分类
        XCTAssertTrue(store.move(id: topA, into: video))
        XCTAssertEqual(store.roots.count, 1) // 顶层只剩"工作"
        XCTAssertEqual(store.roots[0].children[0].children.last?.path, "/tmp/a")

        // 移回顶层
        XCTAssertTrue(store.move(id: topA, into: nil))
        XCTAssertEqual(store.roots.last?.path, "/tmp/a")

        // 往"视频"里再收藏一份 A(不同层允许同路径),再把顶层的 A 移进去 → 同路径拒绝且回滚
        XCTAssertTrue(store.addFolder(name: "A", path: "/tmp/a", into: video))
        XCTAssertFalse(store.move(id: topA, into: video))
        XCTAssertTrue(store.roots.contains { $0.id == topA }) // 顶层的 A 没动
        XCTAssertEqual(store.roots[0].children[0].children.last?.path, "/tmp/a") // 视频里那份也没动
    }

    func testPersistenceRoundTrip() {
        let work = store.addCategory(named: "工作")!
        store.addFolder(name: "A", path: "/tmp/a", into: work)

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.roots.count, 1)
        XCTAssertEqual(reloaded.roots[0].name, "工作")
        XCTAssertEqual(reloaded.roots[0].children.first?.path, "/tmp/a")
    }

    func testExpandedStatePersists() {
        let work = store.addCategory(named: "工作")!
        store.setExpanded(work, false)
        store.setExpanded(work, true)

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertTrue(reloaded.expanded.contains(work.uuidString))
        reloaded.toggleExpanded(work)
        XCTAssertFalse(reloaded.expanded.contains(work.uuidString))
    }
}
