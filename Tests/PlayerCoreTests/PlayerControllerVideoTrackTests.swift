import Foundation
import Testing
@testable import PlayerCore

/// 视频轨（= 界面上的「清晰度」）在**装配层**的行为：命令转发、状态扇出、去重。
///
/// 为什么单独一个套件：它与字幕轨**形状相似但语义不同**（没有"关掉"、标签按分辨率排），
/// 混进字幕套件会让"哪条规则属于谁"重新变得含糊。
@Suite
struct PlayerControllerVideoTrackTests {
    private func track(id: Int64, width: Int = 1280, height: Int = 720) -> VideoTrack {
        VideoTrack(id: id, width: width, height: height, codec: "h264")
    }

    @Test
    func testSelectVideoTrackIsForwardedToKernel() async throws {
        let kernel = FakeKernel(duration: 60)
        let controller = PlayerController(kernel: kernel)
        _ = await controller.start()

        await controller.selectVideoTrack(id: 2)

        let ids = await kernel.selectedVideoTrackIDs
        #expect(ids == [2], "切清晰度必须原样落到内核（`vid`），实际：\(ids)")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    /// ⚠️ 与字幕轨选择**同一条纪律**：内核可能**不接受**这次选择（档位清单已经变了），
    /// 所以装配层**不本地乐观改状态** —— 界面上的当前档位只能来自内核回读。
    ///
    /// 用 `KernelStub`（一个**什么都不上报**的内核）来证这件事：
    /// 若装配层自己抢先把选中项改掉，这条用例就会红。
    @Test
    func testSelectionIsNotAppliedLocallyWithoutKernelConfirmation() async throws {
        let controller = PlayerController(kernel: KernelStub<StubTagA>())
        _ = await controller.start()

        await controller.selectVideoTrack(id: 2)

        let snapshot = await controller.snapshot()
        #expect(
            snapshot.videoTracks.selectedTrackID == nil,
            "内核还没回读之前就显示「已切到某档」，等于界面在替内核说话；实测 selectedTrackID=\(String(describing: snapshot.videoTracks.selectedTrackID))"
        )
        await controller.finishUpdates()
    }

    @Test
    func testVideoTrackStateFlowsOutToUpdatesAndSnapshot() async throws {
        // ⚠️ **只 start() 一次**：`AsyncStream` 被丢弃后会终止，
        //    再 start 一次虽然能拿到新流，但"哪条流是活的"就开始靠记忆了 —— 测试里不该这样。
        let kernel = FakeKernel(duration: 60)
        let controller = PlayerController(kernel: kernel)
        let stream = await controller.start()
        var iterator = stream.makeAsyncIterator()
        let expected = PlayerVideoTrackState(
            tracks: [track(id: 1), track(id: 2, width: 854, height: 480)],
            selectedTrackID: 2
        )

        await kernel.emit(.videoTracksChanged(expected))
        var received: PlayerControllerUpdate?
        while let update = await iterator.next() {
            if case .videoTracksChanged = update {
                received = update
                break
            }
        }

        #expect(received == .videoTracksChanged(expected))
        let snapshot = await controller.snapshot()
        #expect(snapshot.videoTracks == expected, "快照必须同步 —— 界面刷新时不能看到旧档位")
        #expect(snapshot.videoTracks.label == "清晰度：854×480")
        await controller.finishUpdates()
        await kernel.finishEvents()
    }

    @Test
    func testRepeatedIdenticalVideoTrackStateIsNotPublishedTwice() async throws {
        let kernel = FakeKernel(duration: 60)
        let controller = PlayerController(kernel: kernel)
        let stream = await controller.start()
        var iterator = stream.makeAsyncIterator()
        let state = PlayerVideoTrackState(tracks: [track(id: 1)], selectedTrackID: 1)

        await kernel.emit(.videoTracksChanged(state))
        await kernel.emit(.videoTracksChanged(state))
        _ = await iterator.next()

        await kernel.finishEvents()
        var extra: PlayerControllerUpdate?
        while let update = await iterator.next() {
            if case .videoTracksChanged = update { extra = update }
        }
        #expect(extra == nil, "同值重复不该再上报（否则界面会被无意义地重绘）")
        await controller.finishUpdates()
    }
}
