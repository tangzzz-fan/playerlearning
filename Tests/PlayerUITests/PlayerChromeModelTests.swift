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
