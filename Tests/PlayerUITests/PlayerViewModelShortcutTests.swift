import Foundation
import Testing
@testable import PlayerCore
@testable import PlayerUI

/// 快捷键在**装配层**的副作用（`P7-T2`）。
///
/// ⚠️ 为什么这些落在模型层：本项目已按董事长决定移除 UI 自动化 ⇒ 键位的**手感**只能人按，
/// 但**判定与副作用必须由模型兜住**，否则这一票在自动化层面就是零覆盖
/// （"看起来加了快捷键，实际按下去什么都不发生"这种缺陷会完全隐形）。
@Suite
@MainActor
struct PlayerViewModelShortcutTests {
    private func makeModel(duration: Double = 60) async -> (PlayerViewModel, FakeKernel) {
        let kernel = FakeKernel(duration: duration)
        let model = PlayerViewModel(controller: PlayerController(kernel: kernel))
        await model.start()
        return (model, kernel)
    }

    private func loadedModel(duration: Double = 60) async -> (PlayerViewModel, FakeKernel) {
        let (model, kernel) = await makeModel(duration: duration)
        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        try? await Task.sleep(for: .milliseconds(60))
        return (model, kernel)
    }

    // MARK: - 需要内核的那一类：可用性判据与按钮**共用**

    /// 没加载过文件 ⇒ 内核连句柄都没建，四条播放类命令全都会静默 return。
    /// 快捷键必须**同样安静** —— 否则"按钮灰着、空格却能按"会让人以为界面坏了。
    @Test
    func testPlaybackShortcutsDoNothingBeforeAnyLoad() async {
        let (model, kernel) = await makeModel()

        for command in [PlayerShortcutCommand.togglePlayPause, .stop, .skipBackward, .skipForward] {
            await model.handleShortcut(command)
        }
        try? await Task.sleep(for: .milliseconds(50))

        let plays = await kernel.playCallCount
        let pauses = await kernel.pauseCallCount
        let stops = await kernel.stopCallCount
        let seeks = await kernel.seekRequests
        #expect(plays == 0, "未加载时的播放命令必须一条都不发")
        #expect(pauses == 0)
        #expect(stops == 0)
        #expect(seeks.isEmpty)

        await model.teardown()
        await kernel.finishEvents()
    }

    /// 时长未知时按钮是灰的（`canSkip == false`）⇒ `J` / `L` 也该没反应。
    @Test
    func testSkipShortcutsRespectUnknownDuration() async {
        let (model, kernel) = await makeModel(duration: 0)
        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        try? await Task.sleep(for: .milliseconds(60))

        await model.handleShortcut(.skipForward)
        await model.handleShortcut(.skipBackward)

        let seeks = await kernel.seekRequests
        #expect(seeks.isEmpty, "时长未知 ⇒ 跳到哪都说不清，命令不该发出去；实际：\(seeks)")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testSpaceTogglesPlaybackThroughTheKernel() async {
        let (model, kernel) = await loadedModel()

        await model.handleShortcut(.togglePlayPause)
        try? await Task.sleep(for: .milliseconds(60))
        let plays = await kernel.playCallCount
        #expect(plays == 1, "第一次空格应去 play")
        #expect(model.isPlaying)

        await model.handleShortcut(.togglePlayPause)
        try? await Task.sleep(for: .milliseconds(60))
        let pauses = await kernel.pauseCallCount
        #expect(pauses == 1, "第二次空格应去 pause")
        #expect(!model.isPlaying)

        await model.teardown()
        await kernel.finishEvents()
    }

    /// 跳转的目标必须**基于模型当前的播放位置**算出来，而不是把一个写死的值发下去。
    ///
    /// ⚠️ 这里同时钉住一条**刻意的行为**：连按 `L` 两次，在假内核下会得到**同一个目标** ——
    /// 因为位置是**内核权威量**，模型只在收到 `currentTimeChanged` 时才前进，
    /// 而假内核不会回话。这与字幕延迟的处理**故意不同**（那里本地即时生效，`P-043`）：
    /// 延迟是**设置**，位置是**事实** —— 本地猜一个位置会与内核打架（`P-049` 那一族）。
    /// 真内核下第一次 seek 会立刻把新位置报回来，所以人手连按是能连进的。
    @Test
    func testSkipTargetIsBasedOnCurrentPosition() async {
        let (model, kernel) = await loadedModel()
        await kernel.emit(.currentTimeChanged(40))
        try? await Task.sleep(for: .milliseconds(300))

        await model.handleShortcut(.skipForward)
        await model.handleShortcut(.skipBackward)

        let seeks = await kernel.seekRequests
        #expect(seeks == [50, 30], "目标 = 当前位置 ± 10；实际：\(seeks)")
        await model.teardown()
        await kernel.finishEvents()
    }

    /// 上面那条的另一半：**内核一旦把新位置报回来，下一次跳转就以新位置为基准**。
    /// 这才是"相对跳转"真正的核心不变量（少了它，第二条 `L` 永远只前进一格）。
    @Test
    func testSkipFollowsThePositionReportedByTheKernel() async {
        let (model, kernel) = await loadedModel()
        await kernel.emit(.currentTimeChanged(40))
        try? await Task.sleep(for: .milliseconds(300))

        await model.handleShortcut(.skipForward)
        await kernel.emit(.currentTimeChanged(50))
        try? await Task.sleep(for: .milliseconds(300))
        await model.handleShortcut(.skipForward)

        let seeks = await kernel.seekRequests
        #expect(seeks == [50, 60], "第二次必须从内核报回的 50 出发；实际：\(seeks)")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testStopShortcutStops() async {
        let (model, kernel) = await loadedModel()
        await model.handleShortcut(.togglePlayPause)
        try? await Task.sleep(for: .milliseconds(60))

        await model.handleShortcut(.stop)
        try? await Task.sleep(for: .milliseconds(60))

        let stops = await kernel.stopCallCount
        #expect(stops == 1)
        #expect(model.state == .idle)
        await model.teardown()
        await kernel.finishEvents()
    }

    // MARK: - 纯界面的那一类：任何时候都响应

    /// 全屏与有没有视频无关 —— 而且"按了 F 没反应"比"没得看"更让人困惑。
    @Test
    func testFullscreenShortcutWorksWithoutAnyLoad() async {
        let (model, kernel) = await makeModel()

        await model.handleShortcut(.toggleFullscreen)
        #expect(model.fullscreen.isFullscreen, "没加载文件也该能进全屏")
        #expect(model.fullscreen.hidesHostChrome)

        await model.handleShortcut(.exitFullscreen)
        #expect(!model.fullscreen.isFullscreen)

        await model.teardown()
        await kernel.finishEvents()
    }

    /// `Esc` 表达的是**状态**（"回到非全屏"），不是"翻一下" ——
    /// 所以重复按两次不该又进全屏（那正是用 `toggle()` 会犯的错）。
    @Test
    func testExitFullscreenIsIdempotent() async {
        let (model, kernel) = await makeModel()

        await model.handleShortcut(.exitFullscreen)
        #expect(!model.fullscreen.isFullscreen, "本来就不在全屏，退出全屏应保持非全屏")

        await model.handleShortcut(.toggleFullscreen)
        await model.handleShortcut(.exitFullscreen)
        await model.handleShortcut(.exitFullscreen)
        #expect(!model.fullscreen.isFullscreen, "连按两次退出全屏不该又翻回去")

        await model.teardown()
        await kernel.finishEvents()
    }

    /// 结束播放要复位全屏（`PlayerFullscreenModel.reset` 的那条既有规则）——
    /// 快捷键进来的全屏也必须被同一条规则覆盖。
    @Test
    func testTeardownResetsFullscreenReachedByShortcut() async {
        let (model, kernel) = await makeModel()
        await model.handleShortcut(.toggleFullscreen)
        #expect(model.fullscreen.isFullscreen)

        await model.teardown()

        #expect(!model.fullscreen.isFullscreen, "下次进来一开屏就是全屏，用户会以为界面坏了")
        await kernel.finishEvents()
    }
}
