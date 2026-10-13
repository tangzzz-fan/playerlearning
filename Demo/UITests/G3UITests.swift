import XCTest

/// `G3`：**在模拟器上真点一遍** —— 能选文件、能播、能拖进度、能全屏。
///
/// ⚠️ **本文件刻意使用 XCTest**（项目其余测试一律 Swift Testing）。
/// 原因：UI 自动化需要 `XCUIApplication`，而 **Swift Testing 没有等价能力** ——
/// 这不是"忘了迁移"，是工具能力的边界，记录在此以免日后被当成违规清理掉。
final class G3UITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchWithSample() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-autoLoadSample"]
        app.launch()
        return app
    }

    /// 等状态行里的文字出现某段内容（状态行是刻意做成可读文本的，见 `PlayerScreenView`）。
    private func waitForStatus(_ app: XCUIApplication, containing fragment: String, timeout: TimeInterval = 40) {
        let status = app.staticTexts["player.status"]
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "状态行没出现")
        let matched = NSPredicate(format: "label CONTAINS %@", fragment)
        let token = XCTNSPredicateExpectation(predicate: matched, object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [token], timeout: timeout), .completed,
                       "状态行一直没出现「\(fragment)」，当前是：\(status.label)")
    }

    private func waitForStatusNotContaining(_ app: XCUIApplication, _ fragment: String, timeout: TimeInterval = 40) {
        let status = app.staticTexts["player.status"]
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "状态行没出现")
        let matched = NSPredicate(format: "NOT (label CONTAINS %@)", fragment)
        let token = XCTNSPredicateExpectation(predicate: matched, object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [token], timeout: timeout), .completed,
                       "状态行一直没有脱离「\(fragment)」，当前是：\(status.label)")
    }

    /// ① 能播（含出画与出声）
    func testPlaysLoadedFile() {
        let app = launchWithSample()

        waitForStatus(app, containing: "playing")
        waitForStatus(app, containing: "640×360")
        waitForStatus(app, containing: "输出 44100 Hz")

        XCTAssertTrue(app.buttons["player.playPause"].exists)
        XCTAssertTrue(app.buttons["player.fullscreen"].exists)
        XCTAssertTrue(app.buttons["player.openFile"].exists, "必须有选择文件的入口")
    }

    /// ② 能暂停 / 继续
    func testPlayPauseTogglesState() {
        let app = launchWithSample()
        waitForStatus(app, containing: "playing")

        app.buttons["player.playPause"].tap()
        waitForStatus(app, containing: "paused")

        // ⚠️ 不写死"恢复后一定是 readyToPlay"：样例只有 5 秒，
        //    测试跑得慢时它可能已经播完（`finished`）—— 断言"脱离 paused"才是不依赖时序的正确口径。
        app.buttons["player.playPause"].tap()
        waitForStatusNotContaining(app, "paused")
    }

    /// ③ 能拖进度
    ///
    /// ⚠️ 先**暂停**再拖，位置才不会变 —— 否则读数一直在被播放推进，
    /// 断言会变成"和时针赛跑"。然后**两端各拖一次**：
    /// 拖到 95% 读数应离开 0:00，拖到 5% 应回到 0:00。这样与片段长度无关。
    func testScrubbingMovesPlaybackPosition() {
        let app = launchWithSample()
        waitForStatus(app, containing: "playing")

        let current = app.staticTexts["player.currentTime"]
        XCTAssertTrue(current.waitForExistence(timeout: 20), "时间读数没出现")

        app.buttons["player.playPause"].tap()
        waitForStatus(app, containing: "paused")

        let slider = app.sliders["player.progress"]
        XCTAssertTrue(slider.waitForExistence(timeout: 20), "进度条没出现")
        XCTAssertTrue(slider.isEnabled, "时长已知时进度条必须可拖")

        slider.adjust(toNormalizedSliderPosition: 0.95)
        let nearEnd = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != '0:00'"),
            object: current
        )
        XCTAssertEqual(XCTWaiter().wait(for: [nearEnd], timeout: 30), .completed,
                       "拖到 95% 之后读数应离开 0:00，当前 \(current.label)")

        slider.adjust(toNormalizedSliderPosition: 0.05)
        let nearStart = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == '0:00'"),
            object: current
        )
        XCTAssertEqual(XCTWaiter().wait(for: [nearStart], timeout: 30), .completed,
                       "拖到 5% 之后读数应回到 0:00，当前 \(current.label)")
    }

    /// ④ 能全屏（判据：**宿主外壳让位**，不只是画面变大）
    func testFullscreenHidesHostChrome() {
        let app = launchWithSample()
        waitForStatus(app, containing: "playing")

        let hostButton = app.buttons["demo.loadSample"]
        XCTAssertTrue(hostButton.exists, "非全屏时宿主按钮应当在")

        app.buttons["player.fullscreen"].tap()
        XCTAssertFalse(hostButton.waitForExistence(timeout: 3), "全屏后宿主外壳必须让位")

        app.buttons["player.fullscreen"].tap()
        XCTAssertTrue(hostButton.waitForExistence(timeout: 5), "退出全屏后宿主外壳要回来")
    }

    /// ⑤ 能选文件（判据：**选择器真的盖住了界面**）
    ///
    /// ⚠️ 口径说明：这一步只证到"系统选择器被拉起并接管了界面"，
    /// **不**证"在系统选择器里点到某个文件并播起来" —— 后者要跨进程驱动
    /// "文件" App，在 CI 上很不稳。真机/手动复验一次是诚实的补法。
    func testOpenFilePresentsSystemPicker() {
        let app = launchWithSample()
        waitForStatus(app, containing: "playing")

        let openButton = app.buttons["player.openFile"]
        XCTAssertTrue(openButton.isHittable)
        openButton.tap()

        // ⚠️ 口径修正：选择器拉起后宿主按钮**仍在元素树里**（只是被盖住 ⇒ 不再可点），
        //    所以判据是 `isHittable == false`，不是 `exists == false`。
        let covered = NSPredicate(format: "isHittable == false")
        let token = XCTNSPredicateExpectation(predicate: covered, object: openButton)
        XCTAssertEqual(XCTWaiter().wait(for: [token], timeout: 15), .completed,
                       "选择器拉起后应盖住本 App 的按钮（说明它确实接管了界面）")
    }
}
