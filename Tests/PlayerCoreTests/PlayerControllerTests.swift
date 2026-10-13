import CoreGraphics
import Foundation
import Testing
@testable import PlayerCore

private struct StreamProbe {
    private var iterator: AsyncStream<PlayerControllerUpdate>.AsyncIterator

    init(_ stream: AsyncStream<PlayerControllerUpdate>) {
        iterator = stream.makeAsyncIterator()
    }

    /// 只能在内核事件流**已收尾**后调用 —— 否则会等一个可能永不到来的事件而挂死（`P-014`）。
    mutating func drain() async -> [PlayerControllerUpdate] {
        var result: [PlayerControllerUpdate] = []
        while let update = await iterator.next() {
            result.append(update)
        }
        return result
    }

    mutating func next() async -> PlayerControllerUpdate? {
        await iterator.next()
    }
}

private struct ControllerLoadFailure: Error {}

private struct ControllerFixture {
    let controller: PlayerController
    let kernel: FakeKernel
    var probe: StreamProbe
    let resource = PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv"))

    /// 收尾内核事件流 → 排空控制器更新流。
    /// **这是本套件所有断言的统一前置**：只有在"流已结束"的前提下，排空才会终止，
    /// 于是无论实现怎么坏，用例只会**失败**，不会**挂死**。
    mutating func updates() async -> [PlayerControllerUpdate] {
        await kernel.finishEvents()
        return await probe.drain()
    }
}

private func makeFixture(
    interval: Double = PlayerTimeModel.defaultInterval,
    duration: Double = 0,
    naturalSize: CGSize = .zero,
    loadError: (any Error)? = nil
) async -> ControllerFixture {
    let kernel = FakeKernel(duration: duration, naturalSize: naturalSize, loadError: loadError)
    let controller = PlayerController(kernel: kernel, timeInterval: interval)
    let updates = await controller.start()
    return ControllerFixture(controller: controller, kernel: kernel, probe: StreamProbe(updates))
}

@Suite
struct PlayerControllerTests {
    @Test
    func testVideoSizeIsEmittedOnlyWhenItChanges() async throws {
        var fixture = await makeFixture(duration: 60, naturalSize: CGSize(width: 1920, height: 1080))

        try await fixture.controller.load(fixture.resource)
        await fixture.kernel.emit(.videoSizeChanged(CGSize(width: 1920, height: 1080)))
        await fixture.kernel.emit(.videoSizeChanged(CGSize(width: 1280, height: 720)))

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 60)),
                .videoSizeChanged(CGSize(width: 1920, height: 1080)),
                .videoSizeChanged(CGSize(width: 1280, height: 720)),
            ],
            "重复的同尺寸不应上报"
        )
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.naturalSize == CGSize(width: 1280, height: 720))
    }

    @Test
    func testSnapshotBeforeStartIsIdleAndEmpty() async {
        let controller = PlayerController(kernel: FakeKernel())

        let snapshot = await controller.snapshot()

        #expect(snapshot == PlayerControllerSnapshot())
        #expect(snapshot.state == .idle)
        #expect(snapshot.duration == 0)
        #expect(!snapshot.isBuffering)
        #expect(snapshot.naturalSize == .zero)
    }

    @Test
    func testStateUpdatesFollowKernelSequenceAndSkipUnchanged() async throws {
        var fixture = await makeFixture(duration: 120)

        try await fixture.controller.load(fixture.resource)
        await fixture.controller.play()
        await fixture.controller.pause()
        await fixture.kernel.emit(.stateChanged(.paused))
        await fixture.controller.stop()

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 120)),
                .stateChanged(.playing),
                .stateChanged(.paused),
                .stateChanged(.idle),
            ],
            "同态事件不应产生额外上报"
        )
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.state == .idle)
    }

    @Test
    func testIllegalTransitionIsRejectedAndNeverEmitted() async {
        var fixture = await makeFixture()

        await fixture.kernel.emit(.stateChanged(.playing))
        await fixture.kernel.emit(.stateChanged(.readyToPlay))
        await fixture.kernel.emit(.stateChanged(.preparing))

        let updates = await fixture.updates()

        #expect(updates == [.stateChanged(.preparing)], "idle 出发的 .playing / .readyToPlay 都应被拒且不上报")
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.state == .preparing)
    }

    @Test
    func testFailedLoadLeavesControllerFailed() async {
        var fixture = await makeFixture(loadError: ControllerLoadFailure())

        try? await fixture.controller.load(fixture.resource)

        let updates = await fixture.updates()

        #expect(updates == [.stateChanged(.preparing), .stateChanged(.failed)])
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.state == .failed)
    }

    @Test
    func testFailureReportedWhenItArrivesWhileReadyToPlay() async throws {
        var fixture = await makeFixture(duration: 60)

        try await fixture.controller.load(fixture.resource)
        await fixture.kernel.emit(.stateChanged(.failed))

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 60)),
                .stateChanged(.failed),
            ],
            "FILE_LOADED 之后、pause 回执之前失败也必须上报（否则失败被状态机吞掉）"
        )
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.state == .failed)
    }

    @Test
    func testFailureReportedWhenItArrivesWhilePaused() async throws {
        var fixture = await makeFixture(duration: 60)

        try await fixture.controller.load(fixture.resource)
        await fixture.controller.play()
        await fixture.controller.pause()
        await fixture.kernel.emit(.stateChanged(.failed))

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 60)),
                .stateChanged(.playing),
                .stateChanged(.paused),
                .stateChanged(.failed),
            ],
            "暂停中流断掉也必须上报"
        )
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.state == .failed)
    }

    @Test
    func testTimeUpdatesHonorConfiguredInterval() async throws {
        var fixture = await makeFixture(interval: 0.5, duration: 60)

        try await fixture.controller.load(fixture.resource)
        await fixture.kernel.emit(.currentTimeChanged(0.3))
        await fixture.kernel.emit(.currentTimeChanged(0.6))

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 60)),
                .timeChanged(PlayerTimeUpdate(currentTime: 0.6, duration: 60)),
            ],
            "0.3 应被 0.5 s 间隔节流掉"
        )
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.currentTime == 0.6)
        #expect(snapshot.duration == 60)
    }

    @Test
    func testBufferingOnIsEmittedOnceAndReflectedInSnapshot() async throws {
        var fixture = await makeFixture(duration: 60)

        try await fixture.controller.load(fixture.resource)
        await fixture.kernel.emit(.bufferingChanged(true))
        await fixture.kernel.emit(.bufferingChanged(true))

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 60)),
                .bufferingChanged(true),
            ],
            "重复的 true 不应重复上报"
        )
        let snapshot = await fixture.controller.snapshot()
        #expect(snapshot.isBuffering)
    }

    @Test
    func testBufferingOffIsEmittedOnceAndReflectedInSnapshot() async throws {
        var fixture = await makeFixture(duration: 60)

        try await fixture.controller.load(fixture.resource)
        await fixture.kernel.emit(.bufferingChanged(true))
        await fixture.kernel.emit(.bufferingChanged(true))
        await fixture.kernel.emit(.bufferingChanged(false))
        await fixture.kernel.emit(.bufferingChanged(false))

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 60)),
                .bufferingChanged(true),
                .bufferingChanged(false),
            ],
            "重复的 false 不应重复上报"
        )
        let snapshot = await fixture.controller.snapshot()
        #expect(!snapshot.isBuffering)
    }

    @Test
    func testSeekIsClampedByTimeModelBeforeReachingKernel() async throws {
        var fixture = await makeFixture(duration: 100)

        try await fixture.controller.load(fixture.resource)
        let updates = await fixture.updates()
        #expect(updates.count == 3, "先把 load 的三条事件排空，确保模型已拿到 duration")

        await fixture.controller.seek(to: -10)
        await fixture.controller.seek(to: 42)
        await fixture.controller.seek(to: 999)

        let recorded = await fixture.kernel.seekRequests
        #expect(recorded == [0, 42, 100])
    }

    @Test
    func testControlCallsAreForwardedToKernelAndReportedThroughStream() async throws {
        var fixture = await makeFixture(duration: 30)

        try await fixture.controller.load(fixture.resource)
        await fixture.controller.play()
        await fixture.controller.pause()
        await fixture.controller.stop()

        let updates = await fixture.updates()

        #expect(
            updates == [
                .stateChanged(.preparing),
                .stateChanged(.readyToPlay),
                .timeChanged(PlayerTimeUpdate(currentTime: 0, duration: 30)),
                .stateChanged(.playing),
                .stateChanged(.paused),
                .stateChanged(.idle),
            ],
            "play / pause / stop 都应由内核事件驱动上报"
        )
        let playCount = await fixture.kernel.playCallCount
        let pauseCount = await fixture.kernel.pauseCallCount
        let stopCount = await fixture.kernel.stopCallCount
        let loaded = await fixture.kernel.loadedResources
        #expect(playCount == 1)
        #expect(pauseCount == 1)
        #expect(stopCount == 1)
        #expect(loaded == [fixture.resource])
    }

    @Test
    func testFinishUpdatesEndsTheStreamWithoutHanging() async throws {
        var fixture = await makeFixture(duration: 60)

        try await fixture.controller.load(fixture.resource)
        await fixture.controller.finishUpdates()

        let ended = await fixture.probe.next()

        #expect(ended == nil, "finishUpdates 后流应结束，而不是挂死（P-014）")
        await fixture.kernel.finishEvents()
    }

    @Test
    func testStartingAgainEndsThePreviousStream() async {
        let kernel = FakeKernel(duration: 60)
        let controller = PlayerController(kernel: kernel)
        var first = StreamProbe(await controller.start())

        var second = StreamProbe(await controller.start())

        let firstEnded = await first.next()
        #expect(firstEnded == nil, "重开时旧流应被结束，否则旧消费者会永久挂死")

        await kernel.finishEvents()
        let secondEnded = await second.next()
        #expect(secondEnded == nil)
    }
}
