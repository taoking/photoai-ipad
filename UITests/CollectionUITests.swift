import XCTest

/// 收藏夹（F-25）：新建、加入、在收藏夹里看、移出、撤销、删除。在合成库上跑，最后把建的收藏夹删掉。
@MainActor
final class CollectionUITests: XCTestCase {
    private var app: XCUIApplication!
    private var grid: XCUIElement { app.collectionViews["photoGrid"] }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-useSyntheticLibrary", "YES", "-autoAdvance", "NO"]
        app.launch()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
    }

    private func sidebarRow(_ name: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    private func waitForCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in self.grid.cells.count == count }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, "网格应该有 \(count) 张，实际 \(grid.cells.count)", file: file, line: line)
    }

    func testCreateAddRemoveUndoDelete() {
        let name = "测试\(Int(Date().timeIntervalSince1970) % 100_000)"
        let newButton = app.buttons["新建收藏夹"]
        if !newButton.exists { app.buttons["显示边栏"].firstMatch.tap() }
        XCTAssertTrue(newButton.waitForExistence(timeout: 3))
        newButton.tap()
        let alert = app.alerts["新建收藏夹"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText(name)
        alert.buttons["新建"].tap()
        XCTAssertTrue(sidebarRow(name).waitForExistence(timeout: 3))

        // 全部照片里选两张，加入刚建的（它就是“上一次的收藏夹”）。
        sidebarRow("全部照片").tap()
        app.buttons["选择"].tap()
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        app.buttons["收藏夹菜单"].tap()
        app.buttons["加入「\(name)」"].tap()
        app.buttons["完成"].tap()

        sidebarRow(name).tap()
        waitForCount(2)

        // 侧栏按住收藏夹“导出…”：范围的名字和张数隔开（原来名字“111”、26 张显示成“111 26 张”）。
        sidebarRow(name).press(forDuration: 1)
        app.buttons["导出…"].tap()
        let scope = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "收藏夹「\(name)」 · 2 张")).firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 3))
        app.buttons["关闭"].tap()

        // 移出一张，再撤销。
        app.buttons["选择"].tap()
        grid.cells.element(boundBy: 0).tap()
        app.buttons["收藏夹菜单"].tap()
        app.buttons["移出「\(name)」"].tap()
        waitForCount(1)
        app.buttons["撤销"].firstMatch.tap()
        waitForCount(2)
        app.buttons["完成"].tap()

        // 删除收藏夹：照片还在，回到全部照片。
        sidebarRow(name).press(forDuration: 1)
        app.buttons["删除…"].tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.buttons["删除"].tap()
        XCTAssertFalse(sidebarRow(name).waitForExistence(timeout: 2))
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 3))
    }
}
