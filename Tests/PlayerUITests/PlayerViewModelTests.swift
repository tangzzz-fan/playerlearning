import CoreGraphics
import Foundation
import Testing
@testable import PlayerCore
@testable import PlayerUI

@Suite
@MainActor
struct PlayerViewModelTests {
    private func makeModel() async -> (PlayerViewModel, FakeKernel) {
        let kernel = FakeKernel(duration: 0)
        let model = PlayerViewModel(controller: PlayerController(kernel: kernel))
        await model.start()
        return (model, kernel)
    }

    @Test
    func testStartsIdleWithZeroProgress() async {
        let (model, kernel) = await makeModel()

        #expect(model.state == .idle)
        #expect(model.progress == 0)
        #expect(model.currentTime == 0)
        #expect(model.duration == 0)
        await model.teardown()
        await kernel.finishEvents()
    }

    /// ⚠️ 时长未知时必须给 `0` 而不是 `NaN` —— `NaN` 会让进度条布局直接崩。
    @Test
    func testProgressIsZeroWhenDurationIsUnknown() async {
        let (model, kernel) = await makeModel()

        await kernel.emit(.currentTimeChanged(12))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.currentTime == 12)
        #expect(model.duration == 0)
        #expect(model.progress == 0, "时长未知时 progress 必须是 0，不能是 NaN/Infinity")
        await model.teardown()
        await kernel.finishEvents()
    }

    /// ⚠️ 时长**已知**但当前时间非有限 —— 这才真正走到 `isFinite` 那一句。
    /// 上一版用例用 duration = 0，被 `duration > 0` 短路掉了，于是那半句从未被执行
    /// （变异测试直接抓出来：`isFinite` 守卫被删也全绿 —— 「断言盲」）。
    /// `PlayerTimeModel.apply` **不拦** NaN（它原样写入并发布）⇒ UI 层必须自己兜住。
    @Test
    func testProgressStaysZeroWhenCurrentTimeIsNotFinite() async {
        let (model, kernel) = await makeModel()

        await kernel.emit(.durationChanged(100))
        await kernel.emit(.currentTimeChanged(.nan))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.duration == 100)
        #expect(model.currentTime.isNaN, "前置条件：内核确实把非有限值送上来了")
        #expect(model.progress == 0, "NaN 一旦漏进进度条，布局会崩")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testProgressIsClampedToUnitRange() async {
        let (model, kernel) = await makeModel()

        await kernel.emit(.durationChanged(10))
        await kernel.emit(.currentTimeChanged(30))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.progress == 1, "越界的当前时间必须钳到 1")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testAspectRatioFallsBackToSixteenNineBeforeSizeIsKnown() async {
        let (model, kernel) = await makeModel()

        #expect(model.aspectRatio == 16.0 / 9.0, "首帧前要用 16:9 兜底，避免布局跳一下")

        await kernel.emit(.videoSizeChanged(CGSize(width: 640, height: 360)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.aspectRatio == 640.0 / 360.0)

        await kernel.emit(.videoSizeChanged(CGSize(width: 1080, height: 1920)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.aspectRatio == 1080.0 / 1920.0, "竖屏素材要按竖屏比例，不能写死 16:9")
        await model.teardown()
        await kernel.finishEvents()
    }

    /// ⚠️ **必须先 `load`**：`idle → playing` 是**非法迁移**（状态机会拒掉），
    /// 所以"从 idle 直接点播放"永远不会真的播起来 —— 这是刻意的，不是 bug。
    @Test
    func testToggleFlipsBetweenPlayAndPause() async {
        let (model, kernel) = await makeModel()
        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        try? await Task.sleep(for: .milliseconds(50))

        await model.togglePlayPause()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.isPlaying, "可播状态下 toggle 应去 play")

        await model.togglePlayPause()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!model.isPlaying, "playing 时 toggle 应去 pause")

        await model.teardown()
        await kernel.finishEvents()
    }

    /// 把上面那条的反面钉住：**idle 时点播放不该变成 playing** ——
    /// 否则 `P2-T6` 那条"非法迁移必须被拒"的设计就白设了。
    @Test
    func testToggleFromIdleDoesNotStartPlaying() async {
        let (model, kernel) = await makeModel()

        await model.togglePlayPause()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!model.isPlaying, "没有任何文件时不应进入 playing")
        #expect(model.state != .playing)
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testLoadFailureIsSurfacedInsteadOfThrown() async {
        let kernel = FakeKernel(duration: 0, loadError: StubFailure())
        let model = PlayerViewModel(controller: PlayerController(kernel: kernel))
        await model.start()

        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/none.mkv")))

        #expect(model.loadFailure != nil, "失败必须能在界面上被看见，而不是只丢在 try 里")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testSkipUsesCurrentTimeAsBase() async {
        let (model, kernel) = await makeModel()

        await kernel.emit(.durationChanged(100))
        await kernel.emit(.currentTimeChanged(40))
        try? await Task.sleep(for: .milliseconds(50))

        await model.skip(by: 10)
        await model.skip(by: -100)

        let requests = await kernel.seekRequests
        #expect(requests == [50, 0], "跳转要基于当前时间，且由装配层钳制（-100 应落到 0）")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testDiagnosticHookReceivesRawUpdates() async {
        let (model, kernel) = await makeModel()
        var received: [PlayerControllerUpdate] = []
        model.onUpdate = { received.append($0) }

        await kernel.emit(.stateChanged(.preparing))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(received == [.stateChanged(.preparing)])
        await model.teardown()
        await kernel.finishEvents()
    }

    // MARK: - 控制层显隐（装配层侧）

    @Test
    func testChromeStartsVisible() async {
        let (model, kernel) = await makeModel()

        #expect(model.chrome.isVisible, "首帧显示控制层 —— 否则用户不知道点哪")

        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testTogglingChromeFlipsVisibility() async {
        let (model, kernel) = await makeModel()

        model.toggleChrome()
        #expect(!model.chrome.isVisible, "点画面第一下应把控制层收走")

        model.toggleChrome()
        #expect(model.chrome.isVisible)

        await model.teardown()
        await kernel.finishEvents()
    }

    /// 状态一旦离开 `.playing`，控制层必须自己回来。
    /// 这条是「暂停时收起控制层」那个体感问题的防线 —— 用户刚点完暂停就被抢走界面。
    @Test
    func testLeavingPlayingBringsChromeBack() async {
        let (model, kernel) = await makeModel()
        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.emit(.stateChanged(.playing))
        try? await Task.sleep(for: .milliseconds(50))

        model.toggleChrome()
        #expect(!model.chrome.isVisible)

        await kernel.emit(.stateChanged(.paused))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.chrome.isVisible, "暂停后控制层要回来")
        await model.teardown()
        await kernel.finishEvents()
    }

    /// 拖拽期间必须"按住"控制层：手指还在滑块上，层收走了就没法继续拖。
    @Test
    func testScrubbingHoldsChromeOpen() async {
        let (model, kernel) = await makeModel()
        await kernel.emit(.durationChanged(100))
        try? await Task.sleep(for: .milliseconds(50))

        model.beginScrub()
        #expect(model.chrome.holdsOpen)
        #expect(model.chrome.isVisible)
        #expect(!model.chrome.shouldAutoHide(isPlaying: true), "拖拽中不许自动隐藏")

        model.endScrub()
        #expect(!model.chrome.holdsOpen, "松手后要放开，否则控制层永远不再自动隐藏")

        await model.teardown()
        await kernel.finishEvents()
    }
}

private struct StubFailure: Error {}

@Suite
struct PlayerControlBarClockTests {
    @Test
    func testClockFormatsMinutesAndSeconds() {
        #expect(PlayerControlBar.clock(0) == "0:00")
        #expect(PlayerControlBar.clock(9) == "0:09")
        #expect(PlayerControlBar.clock(75) == "1:15")
        #expect(PlayerControlBar.clock(599) == "9:59")
    }

    @Test
    func testClockAddsHoursOnlyWhenNeeded() {
        #expect(PlayerControlBar.clock(3600) == "1:00:00")
        #expect(PlayerControlBar.clock(3725) == "1:02:05")
    }

    @Test
    func testClockNeverShowsNonsense() {
        #expect(PlayerControlBar.clock(-5) == "0:00")
        #expect(PlayerControlBar.clock(.nan) == "0:00")
        #expect(PlayerControlBar.clock(.infinity) == "0:00")
    }

    @Test
    func testClockTruncatesRatherThanRounds() {
        #expect(PlayerControlBar.clock(59.9) == "0:59", "进度显示取整不该让 59.9 提前跳成 1:00")
    }

}
