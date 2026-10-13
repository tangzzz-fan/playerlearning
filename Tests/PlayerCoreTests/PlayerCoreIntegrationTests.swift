import XCTest
@testable import PlayerCore

private struct PlayerCoreHarness {
    var machine = PlayerStateMachine()
    var time = PlayerTimeModel(interval: 0.25)
    private(set) var updates: [PlayerTimeUpdate] = []
    private(set) var rejectedStates: [PlayerState] = []

    mutating func consumeAll(from kernel: FakeKernel, events: AsyncStream<PlayerKernelEvent>) async {
        await kernel.finishEvents()
        for await event in events {
            consume(event)
        }
    }

    private mutating func consume(_ event: PlayerKernelEvent) {
        if case .stateChanged(let newState) = event {
            if machine.transition(to: newState) == .rejected {
                rejectedStates.append(newState)
            }
        }
        if let update = time.apply(event) {
            updates.append(update)
        }
    }
}

final class PlayerCoreIntegrationTests: XCTestCase {
    func testLoadTakesMachineThroughPreparingToReadyAndPublishesDuration() async throws {
        let kernel = FakeKernel(duration: 120)
        var harness = PlayerCoreHarness()
        let events = await kernel.events()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await harness.consumeAll(from: kernel, events: events)

        XCTAssertEqual(harness.machine.state, .readyToPlay)
        XCTAssertEqual(harness.time.duration, 120)
        XCTAssertTrue(harness.rejectedStates.isEmpty, "不应出现被拒的状态：\(harness.rejectedStates)")
    }

    func testPlaybackLifecycleDrivesMachineWithoutRejections() async throws {
        let kernel = FakeKernel(duration: 120)
        var harness = PlayerCoreHarness()
        let events = await kernel.events()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.play()
        await kernel.pause()
        await kernel.play()
        await kernel.stop()
        await harness.consumeAll(from: kernel, events: events)

        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertTrue(harness.rejectedStates.isEmpty, "不应出现被拒的状态：\(harness.rejectedStates)")
    }

    func testFailedLoadLeavesMachineFailedWithoutRejections() async {
        let kernel = FakeKernel(loadError: LoadFailure())
        var harness = PlayerCoreHarness()
        let events = await kernel.events()

        try? await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/broken.mkv")))
        await harness.consumeAll(from: kernel, events: events)

        XCTAssertEqual(harness.machine.state, .failed)
        XCTAssertTrue(harness.rejectedStates.isEmpty, "不应出现被拒的状态：\(harness.rejectedStates)")
    }

    func testRetryAfterFailureIsAccepted() async {
        let kernel = FakeKernel(loadError: LoadFailure())
        var harness = PlayerCoreHarness()
        let events = await kernel.events()

        try? await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/broken.mkv")))
        await kernel.emit(.stateChanged(.preparing))
        await kernel.emit(.stateChanged(.readyToPlay))
        await harness.consumeAll(from: kernel, events: events)

        XCTAssertEqual(harness.machine.state, .readyToPlay)
        XCTAssertTrue(harness.rejectedStates.isEmpty, "不应出现被拒的状态：\(harness.rejectedStates)")
    }

    func testSeekTargetIsClampedBeforeReachingKernel() async throws {
        let kernel = FakeKernel(duration: 100)
        var harness = PlayerCoreHarness()
        let events = await kernel.events()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await harness.consumeAll(from: kernel, events: events)

        let targets = [-10.0, 42.0, 999.0].map(harness.time.clampSeekTarget)
        for target in targets {
            await kernel.seek(to: target)
        }

        let recorded = await kernel.seekRequests
        XCTAssertEqual(targets, [0, 42, 100])
        XCTAssertEqual(recorded, [0, 42, 100])
    }

    func testTimeEventsFeedModelWhileMachineTracksState() async throws {
        let kernel = FakeKernel(duration: 60)
        var harness = PlayerCoreHarness()
        let events = await kernel.events()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.play()
        await kernel.emit(.currentTimeChanged(0))
        await kernel.emit(.currentTimeChanged(0.1))
        await kernel.emit(.currentTimeChanged(0.3))
        await harness.consumeAll(from: kernel, events: events)

        XCTAssertEqual(harness.machine.state, .playing)
        XCTAssertEqual(harness.time.currentTime, 0.3)
        XCTAssertEqual(
            harness.updates.map(\.currentTime),
            [0, 0.3],
            "毫秒级事件应被节流到 0.25 s 粒度"
        )
        XCTAssertTrue(harness.rejectedStates.isEmpty, "不应出现被拒的状态：\(harness.rejectedStates)")
    }

    func testBufferingEventsDoNotDisturbTimeUpdates() async throws {
        let kernel = FakeKernel(duration: 60)
        var harness = PlayerCoreHarness()
        let events = await kernel.events()

        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        await kernel.emit(.bufferingChanged(true))
        await kernel.emit(.bufferingChanged(false))
        await harness.consumeAll(from: kernel, events: events)

        XCTAssertEqual(harness.updates.map(\.currentTime), [0], "只有时长事件产生一次更新")
    }

    func testRegistryResolvesTheFakeKernelForPlayback() async throws {
        let registry = PlayerKernelRegistry(kernelTypes: [FakeKernel.self])

        let kernel = try XCTUnwrap(registry.firstKernelType?.init() as? FakeKernel)
        try await kernel.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))

        let loaded = await kernel.loadedResources
        XCTAssertEqual(loaded.count, 1)
    }
}

private struct LoadFailure: Error {}
