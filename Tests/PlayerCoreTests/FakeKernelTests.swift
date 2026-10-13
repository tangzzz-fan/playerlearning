import XCTest
@testable import PlayerCore

private struct KernelFailure: Error {}

final class FakeKernelTests: XCTestCase {
    func testInitialSnapshotIsIdleAndEmpty() async {
        let kernel = FakeKernel()

        let snapshot = await kernel.snapshot()

        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.currentTime, 0)
        XCTAssertEqual(snapshot.duration, 0)
        XCTAssertFalse(snapshot.isBuffering)
    }

    func testLoadRecordsResourceAndReachesReadyToPlay() async throws {
        let kernel = FakeKernel()
        let resource = PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv"))

        try await kernel.load(resource)

        let loaded = await kernel.loadedResources
        let snapshot = await kernel.snapshot()
        XCTAssertEqual(loaded, [resource])
        XCTAssertEqual(snapshot.state, .readyToPlay)
    }

    func testLoadPublishesDurationOnSnapshot() async throws {
        let kernel = FakeKernel(duration: 42)

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))

        let snapshot = await kernel.snapshot()
        XCTAssertEqual(snapshot.duration, 42)
    }

    func testLoadEmitsStateChangeBeforeDuration() async throws {
        let kernel = FakeKernel(duration: 42)
        var iterator = (await kernel.events()).makeAsyncIterator()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.finishEvents()

        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .stateChanged(.readyToPlay))
        XCTAssertEqual(second, .durationChanged(42))
    }

    func testLoadFailurePropagatesAndLeavesStateFailed() async {
        let kernel = FakeKernel(loadError: KernelFailure())

        do {
            try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
            XCTFail("load should throw")
        } catch {
            let snapshot = await kernel.snapshot()
            let loaded = await kernel.loadedResources
            XCTAssertEqual(snapshot.state, .failed)
            XCTAssertTrue(loaded.isEmpty)
        }
    }

    func testLoadFailureEmitsFailedStateAndNothingElse() async {
        let kernel = FakeKernel(loadError: KernelFailure())
        var iterator = (await kernel.events()).makeAsyncIterator()

        try? await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.finishEvents()

        let event = await iterator.next()
        let beyond = await iterator.next()
        XCTAssertEqual(event, .stateChanged(.failed))
        XCTAssertNil(beyond)
    }

    func testPlayPauseStopRecordCallsAndMoveState() async {
        let kernel = FakeKernel()

        await kernel.play()
        var snapshot = await kernel.snapshot()
        let plays = await kernel.playCallCount
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(plays, 1)

        await kernel.pause()
        snapshot = await kernel.snapshot()
        let pauses = await kernel.pauseCallCount
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(pauses, 1)

        await kernel.stop()
        snapshot = await kernel.snapshot()
        let stops = await kernel.stopCallCount
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(stops, 1)
    }

    func testPlayEmitsStateChange() async {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()

        await kernel.play()
        await kernel.finishEvents()

        let event = await iterator.next()
        XCTAssertEqual(event, .stateChanged(.playing))
    }

    func testEmittedValuesAreReflectedInSnapshot() async {
        let kernel = FakeKernel()

        await kernel.emit(.currentTimeChanged(3.5))
        await kernel.emit(.bufferingChanged(true))

        let snapshot = await kernel.snapshot()
        XCTAssertEqual(snapshot.currentTime, 3.5)
        XCTAssertTrue(snapshot.isBuffering)
    }

    func testEmittedStateChangeIsReflectedInSnapshot() async {
        let kernel = FakeKernel()

        await kernel.emit(.stateChanged(.finished))

        let snapshot = await kernel.snapshot()
        XCTAssertEqual(snapshot.state, .finished)
    }

    func testSeekRecordsRequestedTimeWithoutClamping() async {
        let kernel = FakeKernel(duration: 10)

        await kernel.seek(to: -5)
        await kernel.seek(to: 999)

        let requests = await kernel.seekRequests
        XCTAssertEqual(requests, [-5, 999])
    }

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
        XCTAssertEqual(first, .bufferingChanged(true))
        XCTAssertEqual(second, .currentTimeChanged(1.5))
        XCTAssertEqual(third, .bufferingChanged(false))
        XCTAssertNil(beyond)
    }

    func testFinishEventsEndsStream() async {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()

        await kernel.emit(.bufferingChanged(true))
        await kernel.finishEvents()

        let event = await iterator.next()
        let beyond = await iterator.next()
        XCTAssertEqual(event, .bufferingChanged(true))
        XCTAssertNil(beyond)
    }

    func testEmitAfterFinishEventsIsDiscarded() async {
        let kernel = FakeKernel()
        var iterator = (await kernel.events()).makeAsyncIterator()

        await kernel.finishEvents()
        await kernel.emit(.bufferingChanged(true))

        let event = await iterator.next()
        XCTAssertNil(event)
    }
}
