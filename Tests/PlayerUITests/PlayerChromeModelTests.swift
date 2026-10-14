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

    /// 开关**只发命令**，状态等内核回执（`sub-visibility` 是可观测属性 —— 同 `P2-T5` 的原则）。
    @Test
    func testSubtitleToggleSendsCommandAndReflectsKernelState() async {
        let (model, kernel) = await makeModel()

        await model.toggleSubtitles()
        try? await Task.sleep(for: .milliseconds(50))

        let requests = await kernel.subtitleVisibilityRequests
        #expect(requests == [true], "界面应把「开」这个意图发给内核")
        #expect(model.subtitles.isVisible, "状态要来自内核回执，而不是界面自己记的")
        #expect(!model.subtitles.isDisplaying, "还没有字幕源 ⇒ 不能说正在显示")

        await model.teardown()
        await kernel.finishEvents()
    }

    /// 加载外挂字幕会**经过 SubtitleLoader**（读 → 解编码 → 以 UTF-8 另存），
    /// 所以传给内核的**不是**用户选的那个路径。这条钉住这个约定。
    @Test
    func testLoadSubtitlePreparesAUTF8CopyBeforeHandingToKernel() async throws {
        let (model, kernel) = await makeModel()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("侧载-\(UUID().uuidString).srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\n中文\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        // ⚠️ 必须先有视频：没有文件时挂字幕是无处可挂的（内核连句柄都没建），
        //    `loadSubtitle` 会明确拒绝并给出提示 —— 那是另一条用例（`PlayerViewModelTests`）。
        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await model.loadSubtitle(from: source)

        let added = await kernel.addedSubtitles
        #expect(added.count == 1)
        #expect(added.first?.url != source, "交给内核的必须是我们自己的 UTF-8 副本")
        #expect(added.first?.title == source.lastPathComponent)
        #expect(model.subtitleNote?.contains("SRT") == true, "状态行要如实说出格式与编码，实际：\(model.subtitleNote ?? "nil")")

        await model.teardown()
        await kernel.finishEvents()
        #expect(!FileManager.default.fileExists(atPath: (added.first?.url.path) ?? ""),
                "退出播放器后字幕副本要清掉 —— 残留会让人以为字幕是自己冒出来的")
    }
}

/// 控制层显隐策略。
///
/// 三条前提（**可见 + 播放中 + 未按住**）缺一不可，所以分开断言 ——
/// 合并成一条的话，将来少了一条只会看到"隐藏坏了"，看不出是哪一条。
@Suite
struct PlayerChromeModelTests {
    @Test
    func testStartsVisible() {
        let model = PlayerChromeModel()

        #expect(model.isVisible, "首帧必须显示 —— 一进来一片黑，用户不知道该点哪")
        #expect(!model.holdsOpen)
    }

    @Test
    func testTapTogglesVisibility() {
        var model = PlayerChromeModel()

        model.toggle()
        #expect(!model.isVisible)

        model.toggle()
        #expect(model.isVisible)
    }

    @Test
    func testAutoHideRequiresPlaying() {
        var model = PlayerChromeModel()

        #expect(!model.shouldAutoHide(isPlaying: false), "暂停时不收起：用户十次有九次正要操作")
        // ⚠️ `autoHide` 是 `mutating`，不能直接放进 `#expect` 的 autoclosure（P-029）。
        let hidWhilePaused = model.autoHide(isPlaying: false)
        #expect(!hidWhilePaused)
        #expect(model.isVisible)
    }

    @Test
    func testAutoHideRequiresVisible() {
        var model = PlayerChromeModel()
        model.toggle()

        #expect(!model.shouldAutoHide(isPlaying: true), "已经藏起来了，没有东西可隐")
        let hidAgain = model.autoHide(isPlaying: true)
        #expect(!hidAgain)
    }

    @Test
    func testAutoHideBlockedWhileHoldingOpen() {
        var model = PlayerChromeModel()
        model.beginHoldingOpen()

        #expect(!model.shouldAutoHide(isPlaying: true), "手指还在滑块上，控制层不能走")
        let hidWhileHeld = model.autoHide(isPlaying: true)
        #expect(!hidWhileHeld)
        #expect(model.isVisible)

        model.endHoldingOpen()
        #expect(model.shouldAutoHide(isPlaying: true), "松手后恢复可隐藏")
    }

    @Test
    func testAutoHideHidesAndReportsIt() {
        var model = PlayerChromeModel()

        let hid = model.autoHide(isPlaying: true)
        #expect(hid)
        #expect(!model.isVisible, "到点就该收起来")
        let hidSecondTime = model.autoHide(isPlaying: true)
        #expect(!hidSecondTime, "第二次应如实答 false —— 调用方据此停掉计时器，别空转")
    }

    @Test
    func testBeginHoldingShowsChrome() {
        var model = PlayerChromeModel()
        model.toggle()

        model.beginHoldingOpen()

        #expect(model.isVisible, "要拖就得先看得见它在哪")
    }

    @Test
    func testAutoHideIntervalIsUsable() {
        #expect(PlayerChromeModel().autoHideInterval > 0)
    }
}
