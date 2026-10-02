import XCTest
@testable import FolderSize

@MainActor
final class L10nTests: XCTestCase {
    override func tearDown() {
        AppSettings.shared.language = .system
    }

    func testTextByID() {
        AppSettings.shared.language = .zh
        XCTAssertEqual(L.t("toolbar.search"), "搜索")
        XCTAssertEqual(L.t("col.size"), "大小")

        AppSettings.shared.language = .en
        XCTAssertEqual(L.t("toolbar.search"), "Search")
        XCTAssertEqual(L.t("col.size"), "Size")
    }

    func testTipFallsBackToText() {
        AppSettings.shared.language = .en
        XCTAssertEqual(L.tip("toolbar.search"), "Open the Everything-style search window (⌘F)")
        // 未定义 .tip 的 ID 回落到文字
        XCTAssertEqual(L.tip("tree.reveal"), "Reveal in Finder")
    }

    func testFormatString() {
        AppSettings.shared.language = .en
        XCTAssertEqual(L.f("status.summary", "1,000", "1 GB", 2.5), "1,000 files · 1 GB · 2.5 s")
        AppSettings.shared.language = .zh
        XCTAssertEqual(L.f("status.summary", "1,000", "1 GB", 2.5), "1,000 个文件 · 1 GB · 2.5 s")
    }

    func testUnknownIDReturnsItself() {
        XCTAssertEqual(L.t("no.such.id"), "no.such.id")
    }

    func testSystemLanguageResolves() {
        AppSettings.shared.language = .system
        let expected: AppLanguage = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
        XCTAssertEqual(L.lang, expected)
        XCTAssertEqual(AppLanguage.allCases.count, 3)
    }
}
