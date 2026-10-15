import XCTest

/// Demo 的 **UI 自动化**（`XCUIApplication`）。
///
/// ## 为什么这个文件是 XCTest，而不是项目统一的 Swift Testing
/// UI 自动化需要 `XCUIApplication`，**Swift Testing 没有等价能力** ——
/// 这是工具边界，不是"忘了迁移"。先例写在 `docs/03` L457–458 与 `docs/11` L41–45，
/// 这里再写一遍是为了**日后不被当作违规清理掉**。
///
/// ## 它和 `-exerciseControls` / `-exerciseFinish` 是什么关系
/// 那三个命令行入口是**"UI 自动化被移除"之后的替代品**（`docs/03` L501），
/// 证的是「控制链路 + 内核语义」。本文件证的是**它们证不了的那一段**：
/// **手指/键盘真的点到/按到了那个控件上**。两者互补，不互相替代。
///
/// ## 取证方式：截图 + stderr
/// 每条用例在**关键状态**截一张图挂进测试报告（`XCTAttachment`），
/// 同时把事实打到 stderr —— 这样 `xcodebuild` 日志里能直接读到，
/// 而截图可用 `--result-bundle` + `xcresulttool` 导出（见 README）。
/// 模拟器截图**不需要屏幕录制权限**：`XCUIScreen` 走的是模拟器自己的 framebuffer，
/// 与宿主被 TCC 拦住的 `screencapture` 是两回事。
final class PlayerScreenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // 控制层首帧就显示（`PlayerChromeModel.isVisible` 初值 true）⇒ 等它出现再开始。
        XCTAssertTrue(
            app.buttons["player.playPause"].waitForExistence(timeout: 10),
            "播放器没起来：控制层首帧应当是可见的"
        )
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 取证小工具

    /// 在**当前状态**截图并挂进报告（`keepAlways` ⇒ 成功也保留）。
    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }

    /// 打到 stderr —— `xcodebuild` 日志里可直接读（无缓冲，同 Demo 的取证风格）。
    private func note(_ line: String) {
        FileHandle.standardError.write(Data(("[ui] \(line)\n".utf8)))
    }

    // MARK: - 用例

    /// 骨架：整屏、控制层、诊断行、控制条上的关键入口都在。
    func testPlayerScreenIsUpWithChromeVisible() {
        XCTAssertTrue(app.otherElements["player.tapArea"].exists, "点画面用的手势层不在")
        XCTAssertTrue(app.staticTexts["player.status"].exists, "诊断行不在（它跟着控制层显隐）")
        for identifier in ["player.playPause", "player.subtitles", "player.fullscreen"] {
            XCTAssertTrue(app.buttons[identifier].exists, "控制条上缺少 \(identifier)")
        }
        note("screen=up chrome=visible")
        capture("01-首屏-控制层可见")
    }

    /// 点画面 = 显示 ↔ 隐藏控制层，**两个方向都要证**（只证一个方向的断言对"永远不显示"恒真）。
    func testTappingTheSurfaceTogglesChrome() {
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.exists, "前置：控制层应当是可见的")

        app.otherElements["player.tapArea"].tap()
        XCTAssertTrue(
            playPause.waitForNonExistence(timeout: 5),
            "点画面后控制层应收起 —— 否则画面永远只有一部分"
        )
        note("chrome=hidden")
        capture("02-点画面-控制层收起")

        app.otherElements["player.tapArea"].tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "再点一下应当把控制层叫回来")
        note("chrome=visible")
        capture("03-再点一下-控制层回来")
    }

    /// **全屏的判据用"宿主外壳让位"**，而不是截图比大小：
    /// 调试按钮行只在 `!fullscreen.hidesHostChrome` 时存在（见 `MPVDemoView`），
    /// 所以它的消失/回来是**结构性**证据，不依赖像素。
    func testFullscreenHidesHostChromeAndComesBack() {
        let hostChrome = app.buttons["demo.stop"]
        XCTAssertTrue(hostChrome.exists, "前置：非全屏时调试按钮行应当在")
        capture("04-非全屏-调试行在")

        app.buttons["player.fullscreen"].tap()
        XCTAssertTrue(
            hostChrome.waitForNonExistence(timeout: 5),
            "进全屏后宿主外壳（调试按钮行）应当让位"
        )
        note("fullscreen=on hostChrome=hidden")
        capture("05-全屏-宿主外壳让位")

        // 全屏下控制层会被自动隐藏吗？不会 —— 空间是**用户点出来的**，先点一下确认它还在。
        let fullscreenButton = app.buttons["player.fullscreen"]
        if !fullscreenButton.exists {
            app.otherElements["player.tapArea"].tap()
        }
        XCTAssertTrue(fullscreenButton.waitForExistence(timeout: 5), "全屏后应当还能退出全屏")
        fullscreenButton.tap()
        XCTAssertTrue(hostChrome.waitForExistence(timeout: 5), "再点一次应当退出全屏")
        note("fullscreen=off hostChrome=visible")
        capture("06-退出全屏-宿主外壳回来")
    }

    /// **键盘**：`F` 切全屏。
    ///
    /// 这条正是 `P7-T2` 里标着"只能人按"的那一格 —— 有了 UI 自动化它就能被钉住。
    /// 键的**判定与副作用**早有单测；这里证的是**事件真的送到了那个视图上**
    /// （`onKeyPress` 要求视图有焦点，而"有没有焦点"只有真环境说得清）。
    func testKeyboardShortcutTogglesFullscreen() throws {
        let hostChrome = app.buttons["demo.stop"]
        XCTAssertTrue(hostChrome.exists, "前置：非全屏时调试按钮行应当在")

        app.typeKey("f", modifierFlags: [])

        XCTAssertTrue(
            hostChrome.waitForNonExistence(timeout: 5),
            "按 F 应当进全屏 —— 没反应说明按键事件没送到播放器视图上（焦点问题）"
        )
        note("key=f fullscreen=on")
        capture("07-按F-进全屏")

        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(hostChrome.waitForExistence(timeout: 5), "再按 F 应当退出全屏")
        note("key=f fullscreen=off")
        capture("08-再按F-退出全屏")
    }
}
