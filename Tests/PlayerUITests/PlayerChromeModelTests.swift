import Foundation
import Testing
@testable import PlayerCore
@testable import PlayerUI

@Suite
struct PlayerFullscreenModelTests {
    @Test
    func testStartsInline() {
        let model = PlayerFullscreenModel()

        #expect(model.mode == .inline)
        #expect(!model.hidesHostChrome)
    }

    @Test
    func testToggleEntersAndLeavesFullscreen() {
        var model = PlayerFullscreenModel()

        model.toggle()
        #expect(model.mode == .fullscreen)
        #expect(model.hidesHostChrome, "全屏时宿主外壳必须让位")

        model.toggle()
        #expect(model.mode == .inline)
        #expect(!model.hidesHostChrome)
    }

    @Test
    func testResetReturnsToInline() {
        var model = PlayerFullscreenModel()
        model.toggle()

        model.reset()

        #expect(model.mode == .inline)
        #expect(!model.hidesHostChrome)
    }

    @Test
    func testResetIsIdempotentWhenAlreadyInline() {
        var model = PlayerFullscreenModel()

        model.reset()

        #expect(model.mode == .inline)
    }
}

@Suite
struct PlayerSubtitleToggleTests {
    @Test
    func testStartsOffAndSilent() {
        let toggle = PlayerSubtitleToggle()

        #expect(!toggle.isEnabled)
        #expect(!toggle.hasSource)
        #expect(!toggle.isDisplaying)
        #expect(toggle.label == "字幕：关")
    }

    /// ⚠️ **本类型存在的核心理由**：占位期没有字幕源，
    /// 所以"用户把开关打开"**不等于**"正在显示字幕"。UI 必须如实说出这一点。
    @Test
    func testEnabledWithoutSourceDoesNotPretendToDisplay() {
        var toggle = PlayerSubtitleToggle()

        toggle.toggle()

        #expect(toggle.isEnabled, "开关确实打开了")
        #expect(!toggle.isDisplaying, "但没有字幕源 ⇒ 不能说正在显示")
        #expect(toggle.label == "字幕：开（暂无字幕源）", "必须如实区分「开着但没源」")
    }

    @Test
    func testDisplaysOnlyWhenEnabledAndSourced() {
        var toggle = PlayerSubtitleToggle()

        toggle.setHasSource(true)
        #expect(!toggle.isDisplaying, "有源但开关没开 ⇒ 不显示")

        toggle.toggle()
        #expect(toggle.isDisplaying)
        #expect(toggle.label == "字幕：开")
    }

    @Test
    func testTurningOffHidesEvenWithSource() {
        var toggle = PlayerSubtitleToggle()
        toggle.setHasSource(true)
        toggle.toggle()

        toggle.toggle()

        #expect(!toggle.isEnabled)
        #expect(!toggle.isDisplaying)
        #expect(toggle.label == "字幕：关")
    }
}

@Suite
@MainActor
struct PlayerViewModelChromeTests {
    private func makeModel() async -> (PlayerViewModel, FakeKernel) {
        let kernel = FakeKernel(duration: 60)
        let model = PlayerViewModel(controller: PlayerController(kernel: kernel))
        await model.start()
        return (model, kernel)
    }

    @Test
    func testFullscreenToggleIsExposed() async {
        let (model, kernel) = await makeModel()

        model.toggleFullscreen()
        #expect(model.fullscreen.hidesHostChrome)

        model.toggleFullscreen()
        #expect(!model.fullscreen.hidesHostChrome)

        await model.teardown()
        await kernel.finishEvents()
    }

    /// ⚠️ 退出播放器必须复位全屏 —— 否则下次进来一开屏就是全屏。
    @Test
    func testTeardownResetsFullscreen() async {
        let (model, kernel) = await makeModel()
        model.toggleFullscreen()
        #expect(model.fullscreen.hidesHostChrome)

        await model.teardown()

        #expect(!model.fullscreen.hidesHostChrome, "退出后必须回到非全屏")
        await kernel.finishEvents()
    }

    /// ⚠️ 「换文件时申请访问权」这一步必须被断言 —— 否则把 `begin` 整段删掉也全绿
    /// （变异测试抓到的就是这条）。外部文件不申请访问权就是读不到，是静默失败。
    @Test
    func testLoadClaimsAndTeardownReleasesFileAccess() async {
        let (model, kernel) = await makeModel()
        let url = URL(fileURLWithPath: "/tmp/external.mkv")

        await model.load(PlayerResource(url: url))
        #expect(model.accessedFileURL == url, "加载外部文件必须持有访问权")

        await model.teardown()
        #expect(model.accessedFileURL == nil, "退出必须释放访问权，否则泄漏")

        await kernel.finishEvents()
    }

    @Test
    func testSubtitleToggleIsExposed() async {
        let (model, kernel) = await makeModel()

        model.toggleSubtitles()

        #expect(model.subtitles.isEnabled)
        #expect(!model.subtitles.isDisplaying, "占位期没有字幕源")
        await model.teardown()
        await kernel.finishEvents()
    }
}
