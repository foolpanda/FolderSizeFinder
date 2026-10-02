import XCTest
@testable import FolderSize

@MainActor
final class LaunchersTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: LauncherStore!

    override func setUp() {
        suiteName = "LaunchersTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = LauncherStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFirstRunSeedsCmux() {
        XCTAssertEqual(store.customs.map(\.name), ["cmux"])
        XCTAssertEqual(store.customs.map(\.command), ["cmux"])
    }

    func testEmptiedListDoesNotReseed() {
        store.customs.forEach { store.remove(id: $0.id) }
        XCTAssertTrue(store.customs.isEmpty)
        let reloaded = LauncherStore(defaults: defaults)
        XCTAssertTrue(reloaded.customs.isEmpty)
    }

    func testAddValidation() {
        XCTAssertFalse(store.add(name: "  ", command: "x"))   // 空名
        XCTAssertFalse(store.add(name: "X", command: " "))    // 空命令
        XCTAssertFalse(store.add(name: "cmux", command: "y")) // 重名
        XCTAssertTrue(store.add(name: "VS Code", command: "code {path}"))
        XCTAssertEqual(store.customs.last?.name, "VS Code")
    }

    func testRemoveAndPersistence() {
        let id = store.customs[0].id
        store.add(name: "iTerm", command: "open -a iTerm {path}")
        let reloaded = LauncherStore(defaults: defaults)
        XCTAssertEqual(reloaded.customs.map(\.name), ["cmux", "iTerm"])

        reloaded.remove(id: id)
        let afterRemove = LauncherStore(defaults: defaults)
        XCTAssertEqual(afterRemove.customs.map(\.name), ["iTerm"])
    }

    func testShellLine() {
        // 普通命令:cd + 原命令
        XCTAssertEqual(LauncherStore.shellLine(path: "/tmp/a", command: "cmux"),
                       "cd '/tmp/a' && cmux")
        // {path} 占位符替换(带 shell 转义)
        XCTAssertEqual(LauncherStore.shellLine(path: "/tmp/a b'c", command: "code {path}"),
                       "cd '/tmp/a b'\\''c' && code '/tmp/a b'\\''c'")
        // 空命令:仅 cd
        XCTAssertEqual(LauncherStore.shellLine(path: "/tmp/a", command: "   "),
                       "cd '/tmp/a'")
    }

    func testShellQuoting() {
        XCTAssertEqual(LauncherStore.shellQuoted("/plain/path"), "'/plain/path'")
        XCTAssertEqual(LauncherStore.shellQuoted("it's"), "'it'\\''s'")
    }
}
