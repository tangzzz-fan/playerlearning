import Foundation
import Testing
@testable import PlayerCore
@testable import PlayerUI

@Suite
struct PlayerScrubModelTests {
    @Test
    func testStartsIdle() {
        let model = PlayerScrubModel()

        #expect(!model.isScrubbing)
        #expect(model.previewTime == 0)
        #expect(!model.wasPlayingBeforeScrub)
    }

    @Test
    func testBeginRecordsPlaybackIntentAndPreviewStart() {
        var model = PlayerScrubModel()

        model.begin(currentTime: 12, isPlaying: true)

        #expect(model.isScrubbing)
        #expect(model.previewTime == 12)
        #expect(model.wasPlayingBeforeScrub, "开始拖之前在播 ⇒ 松手后要恢复播放")
    }

    @Test
    func testBeginClampsNegativeAndNonFiniteStart() {
        var model = PlayerScrubModel()

        model.begin(currentTime: -3, isPlaying: false)
        #expect(model.previewTime == 0, "负的起始位置要归零")

        model.begin(currentTime: .nan, isPlaying: false)
        #expect(model.previewTime == 0, "非有限起始位置要归零")
    }

    @Test
    func testUpdateClampsFractionToUnitRange() {
        var model = PlayerScrubModel()
        model.begin(currentTime: 0, isPlaying: false)

        model.update(fraction: 0.5, duration: 100)
        #expect(model.previewTime == 50)

        model.update(fraction: 1.8, duration: 100)
        #expect(model.previewTime == 100, "超过 1 的比例必须钳住，不能拖到时长之外")

        model.update(fraction: -0.4, duration: 100)
        #expect(model.previewTime == 0, "负比例必须钳到 0")
    }

    @Test
    func testUpdateTreatsNonFiniteFractionAsZero() {
        var model = PlayerScrubModel()
        model.begin(currentTime: 30, isPlaying: false)

        model.update(fraction: .nan, duration: 100)

        #expect(model.previewTime == 0, "NaN 比例不能变成 NaN 时间")
    }

    @Test
    func testUpdateWithoutDurationGivesZero() {
        var model = PlayerScrubModel()
        model.begin(currentTime: 10, isPlaying: false)

        model.update(fraction: 0.7, duration: 0)

        #expect(model.previewTime == 0, "时长未知时预览位置只能是 0")
    }

    /// ⚠️ 没按下就动（例如误触 / 视图回调顺序错）**不能**产生预览 ——
    /// 否则会用一次莫名其妙的 seek 打到内核。
    @Test
    func testUpdateIsIgnoredWhenNotScrubbing() {
        var model = PlayerScrubModel()

        model.update(fraction: 0.9, duration: 100)

        #expect(model.previewTime == 0)
    }

    @Test
    func testEndReturnsTargetOnceAndResets() {
        var model = PlayerScrubModel()
        model.begin(currentTime: 0, isPlaying: true)
        model.update(fraction: 0.25, duration: 80)

        let target = model.end()

        #expect(target == 20)
        #expect(!model.isScrubbing)
        #expect(!model.wasPlayingBeforeScrub, "复位后不该再残留「是否在播」")
        #expect(model.end() == nil, "重复松手不得再发一次 seek")
    }

    /// ⚠️ 没按下就松手（点一下进度条）**不应该**发 seek ——
    /// 返回 `nil` 而不是当前预览值，这条是"点一下就跳一下"的防线。
    @Test
    func testEndWithoutBeginReturnsNil() {
        var model = PlayerScrubModel()

        #expect(model.end() == nil)
    }
}

@Suite
@MainActor
struct PlayerViewModelScrubTests {
    private func makeModel(duration: Double) async -> (PlayerViewModel, FakeKernel) {
        let kernel = FakeKernel(duration: duration)
        let model = PlayerViewModel(controller: PlayerController(kernel: kernel))
        await model.start()
        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/scrub.mkv")))
        try? await Task.sleep(for: .milliseconds(80))
        return (model, kernel)
    }

    @Test
    func testDisplayShowsPreviewWhileScrubbing() async {
        let (model, kernel) = await makeModel(duration: 100)

        await kernel.emit(.currentTimeChanged(20))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.displayTime == 20)

        model.beginScrub()
        model.updateScrub(fraction: 0.75)

        #expect(model.displayTime == 75, "拖拽中显示预览，而不是内核时间")
        #expect(model.displayProgress == 0.75)

        // ⚠️ 松手之后不能还被**残留的预览值**劫持（这是上一条变异体存活暴露的缺口：
        //    只断言"拖拽中"的话，把 `isScrubbing` 判断整个删掉也照样绿）。
        model.endScrub()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.displayTime == 20, "松手后回到真实播放位置")
        #expect(model.displayProgress == 0.2, "松手后进度必须回到真实进度")

        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testScrubPausesThenSeeksAndResumes() async {
        let (model, kernel) = await makeModel(duration: 100)
        await model.play()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.isPlaying)

        model.beginScrub()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!model.isPlaying, "拖拽期间必须先暂停，否则声音会在手指底下继续走")
        let seeksDuringDrag = await kernel.seekRequests
        #expect(seeksDuringDrag.isEmpty, "**拖拽过程中一次 seek 都不该发**")

        model.updateScrub(fraction: 0.3)
        model.updateScrub(fraction: 0.6)
        model.endScrub()
        try? await Task.sleep(for: .milliseconds(80))

        let requests = await kernel.seekRequests
        #expect(requests == [60], "松手只发一次 seek，落点是最后一次预览")
        #expect(model.isPlaying, "本来在播 ⇒ 松手后恢复播放")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testScrubOnPausedPlayerDoesNotStartPlayback() async {
        let (model, kernel) = await makeModel(duration: 100)

        model.beginScrub()
        model.updateScrub(fraction: 0.5)
        model.endScrub()
        try? await Task.sleep(for: .milliseconds(80))

        let requests = await kernel.seekRequests
        #expect(requests == [50])
        #expect(!model.isPlaying, "本来没在播 ⇒ 松手后不该自作主张播起来")
        await model.teardown()
        await kernel.finishEvents()
    }

    @Test
    func testCannotScrubBeforeDurationIsKnown() async {
        let kernel = FakeKernel(duration: 0)
        let model = PlayerViewModel(controller: PlayerController(kernel: kernel))
        await model.start()

        #expect(!model.canScrub, "时长未知时不给拖（拖了也不知道拖到哪）")
        await model.teardown()
        await kernel.finishEvents()
    }
}
