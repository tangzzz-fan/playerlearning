import CoreGraphics
import Foundation
import Testing
@testable import PlayerCore

private struct KernelFailure: Error {}

@Suite
struct FakeKernelTests {
    @Test
    func testInitialSnapshotIsIdleAndEmpty() async {
        let kernel = FakeKernel()

        let snapshot = await kernel.snapshot()

        #expect(snapshot.state == .idle)
        #expect(snapshot.currentTime == 0)
        #expect(snapshot.duration == 0)
        #expect(!snapshot.isBuffering)
    }

    @Test
    func testLoadRecordsResourceAndReachesReadyToPlay() async throws {
        let kernel = FakeKernel()
        let resource = PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv"))

        try await kernel.load(resource)

        let loaded = await kernel.loadedResources
        let snapshot = await kernel.snapshot()
        #expect(loaded == [resource])
        #expect(snapshot.state == .readyToPlay)
    }

    @Test
    func testLoadPublishesDurationOnSnapshot() async throws {
        let kernel = FakeKernel(duration: 42)

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))

        let snapshot = await kernel.snapshot()
        #expect(snapshot.duration == 42)
    }

    @Test
    func testLoadEmitsPreparingThenReadyThenDuration() async throws {
        let kernel = FakeKernel(duration: 42)
        var iterator = (await kernel.events()).makeAsyncIterator()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.finishEvents()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        let beyond = await iterator.next()
        #expect(first == .stateChanged(.preparing))
        #expect(second == .stateChanged(.readyToPlay))
        #expect(third == .durationChanged(42))
        #expect(beyond == nil, "尺寸未知（.zero）时不应上报一个假尺寸")
    }

    @Test
    func testLoadReportsScriptedNaturalSize() async throws {
        let kernel = FakeKernel(duration: 42, naturalSize: CGSize(width: 1920, height: 1080))
        var iterator = (await kernel.events()).makeAsyncIterator()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.finishEvents()

        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        let size = await iterator.next()
        let snapshot = await kernel.snapshot()
        #expect(size == .videoSizeChanged(CGSize(width: 1920, height: 1080)))
        #expect(snapshot.naturalSize == CGSize(width: 1920, height: 1080))
    }

    @Test
    func testInitialSnapshotHasZeroNaturalSize() async {
        let snapshot = await FakeKernel().snapshot()

        #expect(snapshot.naturalSize == .zero)
    }

    @Test
    func testLoadFailurePropagatesAndLeavesStateFailed() async throws {
        let kernel = FakeKernel(loadError: KernelFailure())

        await #expect(throws: KernelFailure.self) {
            try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        }

        let snapshot = await kernel.snapshot()
        let loaded = await kernel.loadedResources
        #expect(snapshot.state == .failed)
        #expect(loaded.isEmpty)
    }

    @Test
    func testLoadFailureEmitsPreparingThenFailedAndNothingElse() async {
        let kernel = FakeKernel(loadError: KernelFailure())
        var iterator = (await kernel.events()).makeAsyncIterator()

        try? await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.finishEvents()

        let first = await iterator.next()
        let second = await iterator.next()
        let beyond = await iterator.next()
        #expect(first == .stateChanged(.preparing))
        #expect(second == .stateChanged(.failed))
        #expect(beyond == nil)
    }

    @Test
    func testPlayPauseStopRecordCallsAndMoveState() async {
        let kernel = FakeKernel()

        await kernel.play()
        var snapshot = await kernel.snapshot()
        let plays = await kernel.playCallCount
        #expect(snapshot.state == .playing)
        #expect(plays == 1)

        await kernel.pause()
        snapshot = await kernel.snapshot()
        let pauses = await kernel.pauseCallCount
        #expect(snapshot.state == .paused)
        #expect(pauses == 1)

        await kernel.stop()
        snapshot = await kernel.snapshot()
        let stops = await kernel.stopCallCount
        #expect(snapshot.state == .idle)
        #expect(stops == 1)
    }

    @Test
    func testPlayEmitsStateChange() async {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()

        await kernel.play()
        await kernel.finishEvents()

        let event = await iterator.next()
        #expect(event == .stateChanged(.playing))
    }

    @Test
    func testEmittedValuesAreReflectedInSnapshot() async {
        let kernel = FakeKernel()

        await kernel.emit(.currentTimeChanged(3.5))
        await kernel.emit(.bufferingChanged(true))

        let snapshot = await kernel.snapshot()
        #expect(snapshot.currentTime == 3.5)
        #expect(snapshot.isBuffering)
    }

    @Test
    func testEmittedStateChangeIsReflectedInSnapshot() async {
        let kernel = FakeKernel()

        await kernel.emit(.stateChanged(.finished))

        let snapshot = await kernel.snapshot()
        #expect(snapshot.state == .finished)
    }

    @Test
    func testSeekRecordsRequestedTimeWithoutClamping() async {
        let kernel = FakeKernel(duration: 10)

        await kernel.seek(to: -5)
        await kernel.seek(to: 999)

        let requests = await kernel.seekRequests
        #expect(requests == [-5, 999])
    }

    @Test
    func testEmittedEventsArriveInOrder() async {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()

        await kernel.emit(.bufferingChanged(true))
        await kernel.emit(.currentTimeChanged(1.5))
        await kernel.emit(.bufferingChanged(false))
        await kernel.finishEvents()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        let beyond = await iterator.next()
        #expect(first == .bufferingChanged(true))
        #expect(second == .currentTimeChanged(1.5))
        #expect(third == .bufferingChanged(false))
        #expect(beyond == nil)
    }

    @Test
    func testFinishEventsEndsStream() async {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()

        await kernel.emit(.bufferingChanged(true))
        await kernel.finishEvents()

        let event = await iterator.next()
        let beyond = await iterator.next()
        #expect(event == .bufferingChanged(true))
        #expect(beyond == nil)
    }

    @Test
    func testEmitAfterFinishEventsIsDiscarded() async {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()

        await kernel.finishEvents()
        await kernel.emit(.bufferingChanged(true))

        let event = await iterator.next()
        #expect(event == nil)
    }

    /// 切清晰度必须**真的动状态并上报**。
    ///
    /// 假内核的价值就在于"照真内核的语义走"（`addSubtitle` 那条注释同理）：
    /// 只记一笔然后什么都不发生，会让装配层与界面的测试**永远测不到状态变化** ——
    /// 于是"切了没反应"这个缺陷在测试里是隐形的。
    @Test
    func testSelectVideoTrackMovesSelectionAndEmitsChange() async throws {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()
        let tracks = [
            VideoTrack(id: 1, width: 1280, height: 720),
            VideoTrack(id: 2, width: 854, height: 480),
        ]

        // 档位清单在真内核里来自 `track-list`；这里直接灌进去。
        await kernel.emit(.videoTracksChanged(PlayerVideoTrackState(tracks: tracks, selectedTrackID: 1)))
        _ = await iterator.next()

        await kernel.selectVideoTrack(id: 2)

        let ids = await kernel.selectedVideoTrackIDs
        #expect(ids == [2])
        let emitted = await iterator.next()
        #expect(emitted == .videoTracksChanged(PlayerVideoTrackState(tracks: tracks, selectedTrackID: 2)))
        let snapshot = await kernel.snapshot()
        #expect(snapshot.videoTracks.selectedTrackID == 2)
        #expect(snapshot.videoTracks.label == "清晰度：854×480")
    }

    /// 选中"已经选中的那一档"不该再上报 —— 否则菜单点一下就是一个无意义的全界面重绘。
    @Test
    func testSelectingTheAlreadySelectedVideoTrackEmitsNothing() async throws {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()
        let state = PlayerVideoTrackState(tracks: [VideoTrack(id: 1, width: 1280, height: 720)], selectedTrackID: 1)

        await kernel.emit(.videoTracksChanged(state))
        _ = await iterator.next()

        await kernel.selectVideoTrack(id: 1)
        await kernel.finishEvents()

        let emitted = await iterator.next()
        #expect(emitted == nil, "同值不该再上报")
        let ids = await kernel.selectedVideoTrackIDs
        #expect(ids == [1], "但请求本身要如实记下来（那是「内核收到了什么」的证据）")
    }
}
