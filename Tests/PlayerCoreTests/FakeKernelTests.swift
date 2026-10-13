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
        #expect(beyond == nil)
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
}
