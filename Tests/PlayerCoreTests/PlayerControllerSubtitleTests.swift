import Foundation
import Testing
@testable import PlayerCore

/// 字幕在**装配层**的行为：命令转发、钳制归属、状态扇出。
@Suite
struct PlayerControllerSubtitleTests {
    private func makeController() async -> (PlayerController, FakeKernel) {
        let kernel = FakeKernel(duration: 60)
        let controller = PlayerController(kernel: kernel)
        _ = await controller.start()
        return (controller, kernel)
    }

    @Test
    func testAddSubtitleDefaultsTitleToFileName() async throws {
        let (controller, kernel) = await makeController()

        await controller.addSubtitle(url: URL(fileURLWithPath: "/tmp/中文字幕.srt"))

        let added = await kernel.addedSubtitles
        #expect(added.count == 1)
        #expect(added.first?.title == "中文字幕.srt", "内核拿不到更友好的名字，总得给界面一个可读的字")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    @Test
    func testSelectingNoTrackForwardsNil() async throws {
        let (controller, kernel) = await makeController()

        await controller.selectSubtitleTrack(id: nil)

        let ids = await kernel.selectedSubtitleTrackIDs
        #expect(ids == [nil], "`nil` 必须原样传给内核（那是 `sid=no`），不能被吞掉")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    /// ⚠️ 钳制**归装配层**（目标区间是模型知识），内核只管执行 —— 与 `seek` 同一条原则。
    @Test
    func testDelayIsClampedBeforeReachingTheKernel() async throws {
        let (controller, kernel) = await makeController()

        await controller.setSubtitleDelay(9999)
        await controller.setSubtitleDelay(-9999)
        await controller.setSubtitleDelay(.nan)

        let requested = await kernel.subtitleDelayRequests
        #expect(requested == [
            SubtitleTimeline.delayRange.upperBound,
            SubtitleTimeline.delayRange.lowerBound,
            0,
        ], "内核收到的必须已经是合法值，实际：\(requested)")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    @Test
    func testAdjustDelayIsRelative() async throws {
        let (controller, kernel) = await makeController()

        await controller.adjustSubtitleDelay(by: 0.5)
        await controller.adjustSubtitleDelay(by: 0.5)
        await controller.adjustSubtitleDelay(by: -1.0)

        let requested = await kernel.subtitleDelayRequests
        #expect(requested == [0.5, 1.0, 0], "相对调整要基于**当前值**，实际：\(requested)")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    @Test
    func testToggleFlipsFromCurrentStateNotFromASeed() async throws {
        let (controller, kernel) = await makeController()

        // 第一次：当前不可见 ⇒ 请求 true
        await controller.toggleSubtitleVisibility()
        // 第二次：本地已即时生效为 true ⇒ 请求 false
        await controller.toggleSubtitleVisibility()

        let requested = await kernel.subtitleVisibilityRequests
        #expect(requested == [true, false], "取反必须基于**控制器持有的当前状态**，实际：\(requested)")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    @Test
    func testSubtitleStateFlowsOutToUpdatesAndSnapshot() async throws {
        // ⚠️ **只 start() 一次**：`AsyncStream` 被丢弃后会终止，
        //    再 start 一次虽然能拿到新流，但"哪条流是活的"就开始靠记忆了 —— 测试里不该这样。
        let kernel = FakeKernel(duration: 60)
        let controller = PlayerController(kernel: kernel)
        let stream = await controller.start()
        var iterator = stream.makeAsyncIterator()
        let track = SubtitleTrack(id: 42, title: "中文", isExternal: true)
        let expected = PlayerSubtitleState(tracks: [track], selectedTrackID: 42, isVisible: true)

        await kernel.emit(.subtitlesChanged(expected))
        var received: PlayerControllerUpdate?
        while let update = await iterator.next() {
            if case .subtitlesChanged = update {
                received = update
                break
            }
        }

        #expect(received == .subtitlesChanged(expected))
        let snapshot = await controller.snapshot()
        #expect(snapshot.subtitles == expected, "快照必须同步 —— 界面刷新时不能看到旧字幕状态")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    @Test
    func testRepeatedIdenticalSubtitleStateIsNotPublishedTwice() async throws {
        let kernel = FakeKernel(duration: 60)
        let controller = PlayerController(kernel: kernel)
        let stream = await controller.start()
        var iterator = stream.makeAsyncIterator()
        let state = PlayerSubtitleState(
            tracks: [SubtitleTrack(id: 1, title: "中")],
            selectedTrackID: 1,
            isVisible: true
        )

        await kernel.emit(.subtitlesChanged(state))
        await kernel.emit(.subtitlesChanged(state))
        _ = await iterator.next()

        await kernel.finishEvents()
        var extra: PlayerControllerUpdate?
        while let update = await iterator.next() {
            if case .subtitlesChanged = update { extra = update }
        }
        #expect(extra == nil, "同值重复不该再上报（否则界面会被无意义地重绘）")
        await controller.finishUpdates()
    }
}
