import XCTest

/// 单张视图和选片（F-12、F-13、F-20 – F-23），在模拟器上用 1 万张的合成库跑。
/// 合成库在模拟器里一直留着，改过的星级下次还在，所以每个用例先把要测的值设成已知状态。
@MainActor
final class SingleViewUITests: XCTestCase {
    private var app: XCUIApplication!

    private var grid: XCUIElement { app.collectionViews["photoGrid"] }
    private var pager: XCUIElement { app.collectionViews["photoPager"] }
    private var pageIndex: String { app.staticTexts["pageIndex"].label }

    private func launch(autoAdvance: Bool) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-useSyntheticLibrary", "YES", "-autoAdvance", autoAdvance ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
    }

    private func openFirst() {
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["返回网格"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["pageIndex"].waitForExistence(timeout: 2))
    }

    private func waitFor(_ element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// 打星、⌘Z 撤销、按钮重做。
    func testRateUndoRedo() {
        launch(autoAdvance: false)
        openFirst()
        let three = app.buttons["3 星"]
        app.buttons["清除星级"].tap()
        XCTAssertTrue(waitFor(three, value: ""))
        three.tap()
        XCTAssertTrue(waitFor(three, value: "当前"))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitFor(three, value: ""))
        app.buttons["single-重做"].tap()
        XCTAssertTrue(waitFor(three, value: "当前"))
    }

    /// 外接键盘（F-26）：网格里数字（没选照片只提示）、空格打开第一张；单张视图里数字打星、P / U 标记、← → 翻页、⌘. 回网格。
    /// 没放进来的（模拟器上测不了，真机验）：`Esc` 模拟器上收不到；单张视图关掉后网格的快捷键时有时无。
    /// 网格的工具栏在单张视图后面也看得见，回没回网格看“返回网格”还在不在。
    /// 名字以 Z 开头排在最后：模拟器的键盘状态在用例之间会留下来，紧接着跑的 ⌘Z（`testRateUndoRedo`）会收不到。
    func testZKeyboardShortcuts() {
        launch(autoAdvance: false)
        let back = app.buttons["返回网格"]
        app.typeKey("1", modifierFlags: [])
        let hint = app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label == '先选中照片'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 3))
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 / '")).firstMatch.waitForExistence(timeout: 5))
        // 单张视图出来后翻页视图才做第一响应者，太早按的键会丢。
        sleep(1)
        app.typeKey("0", modifierFlags: [])
        XCTAssertTrue(waitFor(app.buttons["4 星"], value: ""))
        app.typeKey("4", modifierFlags: [])
        XCTAssertTrue(waitFor(app.buttons["4 星"], value: "当前"))
        app.typeKey("u", modifierFlags: [])
        app.typeKey("p", modifierFlags: [])
        XCTAssertTrue(waitFor(app.buttons["single-pick"], value: "当前"))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 / '")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 / '")).firstMatch.waitForExistence(timeout: 5))
        // 合成库一直留着：第一张改回没星、没标记，别的用例（自动前进）要用。
        app.typeKey("0", modifierFlags: [])
        app.typeKey("u", modifierFlags: [])
        XCTAssertTrue(waitFor(app.buttons["single-pick"], value: ""))
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(back.waitForNonExistence(timeout: 3))
    }

    /// 照片左边上下拖动改星级（照 Lightroom iPad）：往上拖 140 点是 3 星，再往下拖 70 点是 2 星；不翻页、不回网格。
    func testDragOnLeftChangesRating() {
        launch(autoAdvance: false)
        openFirst()
        app.buttons["清除星级"].tap()
        XCTAssertTrue(waitFor(app.buttons["3 星"], value: ""))
        let start = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
        // 慢慢拖、停一下再松手：拖得快时 XCUITest 松手前最后一段送不到（140 点只收到 109 点）。
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -140)), withVelocity: 300, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitFor(app.buttons["3 星"], value: "当前"))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 70)), withVelocity: 300, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitFor(app.buttons["2 星"], value: "当前"))
        XCTAssertTrue(pageIndex.hasPrefix("1 / "))
        XCTAssertTrue(app.buttons["返回网格"].exists)
        app.buttons["single-撤销"].tap()
        XCTAssertTrue(waitFor(app.buttons["3 星"], value: "当前"))
    }

    /// 左右滑翻页、胶片条跳页、往下滑回网格。
    func testSwipePagingAndDismiss() {
        launch(autoAdvance: false)
        openFirst()
        XCTAssertTrue(pageIndex.hasPrefix("1 / "))
        pager.swipeLeft()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 / '")).firstMatch.waitForExistence(timeout: 5))
        pager.swipeRight()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 / '")).firstMatch.waitForExistence(timeout: 5))
        app.collectionViews["filmstrip"].cells.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '3 / '")).firstMatch.waitForExistence(timeout: 5))

        let start = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["选择"].waitForExistence(timeout: 3))
    }

    /// 自动前进：标记后跳到下一张；撤销跳回刚才那张。
    func testAutoAdvanceAndUndoReturns() {
        launch(autoAdvance: true)
        openFirst()
        XCTAssertTrue(pageIndex.hasPrefix("1 / "))
        app.buttons["single-pick"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 / '")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["single-撤销"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 / '")).firstMatch.waitForExistence(timeout: 5))
    }

    /// 双击放大到 50%：合成库没有原图，提示读不了（真卡上这里换成原图）。
    func testDoubleTapZoomAsksForOriginal() {
        launch(autoAdvance: false)
        openFirst()
        pager.doubleTap()
        let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '原图'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        pager.doubleTap()
    }

    /// 筛选 Pick，单张视图里改成 Reject：照片留在结果里；回网格点“刷新结果”才离开（F-22）。
    func testFilterKeepsResultUntilRefresh() {
        launch(autoAdvance: false)
        app.buttons["Pick"].tap()
        XCTAssertTrue(waitFor(app.buttons["Pick"], value: "已选"))
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 5))
        openFirst()
        let total = pageIndex.components(separatedBy: " / ").last ?? ""
        app.buttons["single-reject"].tap()
        XCTAssertTrue(waitFor(app.buttons["single-reject"], value: "当前"))
        XCTAssertEqual(pageIndex.components(separatedBy: " / ").last, total)
        app.buttons["返回网格"].tap()

        let refresh = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '刷新结果'")).firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 2))
        refresh.tap()
        XCTAssertFalse(refresh.waitForExistence(timeout: 1))
        // 收尾：撤销 Reject（照片回到 Pick），清除筛选。
        app.buttons["撤销"].tap()
        let clear = app.buttons["清除筛选"]
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: clear)
        if XCTWaiter().wait(for: [hittable], timeout: 3) != .completed {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
        }
        clear.tap()
        XCTAssertTrue(waitFor(app.buttons["Pick"], value: ""))
    }
}
