import XCTest

/// 导出面板、设置、清卡检查（F-30、F-40、F-50）。合成库没有原图，导不了也不能清（别的界面测试要用它），
/// 这里只看面板打得开、条件对；真正的导出和清卡在核心层测试和真机上测。
@MainActor
final class ExportAndClearUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 表单里一行的标题和值合成一个元素，按“包含”找。
    private func text(_ part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-useSyntheticLibrary", "YES", "-autoAdvance", "NO"]
        app.launch()
        XCTAssertTrue(app.collectionViews["photoGrid"].cells.firstMatch.waitForExistence(timeout: 30))
    }

    /// 选两张点“导出”：范围是所选的 2 张；合成库导不了，“开始导出”是灰的。
    func testExportSheetForSelection() {
        app.buttons["选择"].tap()
        let grid = app.collectionViews["photoGrid"]
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        app.buttons["导出"].tap()
        XCTAssertTrue(text("所选的 2 张").waitForExistence(timeout: 3))
        XCTAssertTrue(text("性能测试库没有原图，导不了").exists)
        XCTAssertFalse(app.buttons["开始导出"].isEnabled)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 3))
        app.buttons["完成"].tap()
    }

    /// 设置里看存储用量、进清卡检查（不真的清）。
    func testSettingsAndClearCheck() {
        // 设置在侧栏顶上。
        let settings = app.buttons["设置"]
        if !settings.exists { app.buttons["显示边栏"].firstMatch.tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        XCTAssertTrue(app.buttons["读取存储卡"].waitForExistence(timeout: 3))
        XCTAssertTrue(text("10000 张").waitForExistence(timeout: 3))
        // 上面加了“存储卡”一节，清卡要往下翻才看得到。
        let clear = app.buttons["清卡…"]
        if !clear.exists { app.swipeUp() }
        clear.tap()
        XCTAssertTrue(text("选过但没导出").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["清卡"].isEnabled)
        app.buttons["清卡"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS '卡上的文件不受影响'")).firstMatch.exists)
        app.alerts.firstMatch.buttons["取消"].tap()
    }
}
