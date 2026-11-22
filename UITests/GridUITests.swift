import XCTest

/// 网格的交互（F-11），在模拟器上用 1 万张的合成库跑：
/// `xcodebuild test -scheme PhotoAI-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'`
@MainActor
final class GridUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 侧栏的 List 也是一个 collection view，只认网格。
    private var grid: XCUIElement { app.collectionViews["photoGrid"] }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-useSyntheticLibrary", "YES", "-autoAdvance", "NO"]
        app.launch()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
    }

    func testTapSelectAndDragSelect() {
        app.buttons["选择"].tap()
        let cells = grid.cells
        cells.element(boundBy: 0).tap()
        cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["已选 2 张"].waitForExistence(timeout: 2))
        // 再点一下取消。
        cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["已选 1 张"].waitForExistence(timeout: 2))

        // 从第 3 格横着拖到第 6 格：连选 4 格。
        let from = cells.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let to = cells.element(boundBy: 5).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(app.staticTexts["已选 5 张"].waitForExistence(timeout: 2))

        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["选择"].waitForExistence(timeout: 2))
    }

    func testOpenSingleAndPinch() {
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["返回网格"].waitForExistence(timeout: 2))
        app.buttons["返回网格"].tap()
        XCTAssertTrue(app.buttons["选择"].waitForExistence(timeout: 2))

        grid.pinch(withScale: 2, velocity: 1)
        grid.pinch(withScale: 0.4, velocity: -1)
        grid.swipeUp(velocity: .fast)
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 2))
    }

    func testSidebarDayAndSort() {
        // 侧栏点一天，标题变成那一天；排序换成旧 → 新。
        let day = app.cells.containing(NSPredicate(format: "label CONTAINS '日 周'")).firstMatch
        if !day.exists { app.buttons["显示边栏"].firstMatch.tap() }
        XCTAssertTrue(day.waitForExistence(timeout: 2))
        day.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 2))
        app.buttons["排序"].tap()
        app.buttons["拍摄时间：旧 → 新"].tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 2))
    }
}
