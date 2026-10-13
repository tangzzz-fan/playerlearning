import XCTest
@testable import PlayerCore

final class PlayerTimeStreamTests: XCTestCase {
    func testStreamPublishesThrottledUpdates() async {
        let kernel = FakeKernel()
        let model = PlayerTimeModel(interval: 0.5)
        let events = await kernel.events()
        var iterator = model.updates(from: events).makeAsyncIterator()

        await kernel.emit(.currentTimeChanged(0))
        await kernel.emit(.currentTimeChanged(0.3))
        await kernel.emit(.currentTimeChanged(0.6))
        await kernel.finishEvents()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual(first?.currentTime, 0)
        XCTAssertEqual(second?.currentTime, 0.6)
        XCTAssertNil(third)
    }

    func testStreamCarriesDurationAlongsideTime() async {
        let kernel = FakeKernel()
        let model = PlayerTimeModel(interval: 0.25)
        let events = await kernel.events()
        var iterator = model.updates(from: events).makeAsyncIterator()

        await kernel.emit(.durationChanged(90))
        await kernel.emit(.currentTimeChanged(1))
        await kernel.finishEvents()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual(first, PlayerTimeUpdate(currentTime: 0, duration: 90))
        XCTAssertEqual(second, PlayerTimeUpdate(currentTime: 1, duration: 90))
        XCTAssertNil(third)
    }

    func testStreamIgnoresEventsUnrelatedToTime() async {
        let kernel = FakeKernel()
        let model = PlayerTimeModel(interval: 0.25)
        let events = await kernel.events()
        var iterator = model.updates(from: events).makeAsyncIterator()

        await kernel.emit(.stateChanged(.playing))
        await kernel.emit(.bufferingChanged(true))
        await kernel.emit(.stateChanged(.paused))
        await kernel.finishEvents()

        let update = await iterator.next()
        XCTAssertNil(update)
    }

    func testStreamTerminatesWhenEventStreamFinishes() async {
        let kernel = FakeKernel()
        let model = PlayerTimeModel(interval: 0.25)
        let events = await kernel.events()
        var iterator = model.updates(from: events).makeAsyncIterator()

        await kernel.finishEvents()

        let update = await iterator.next()
        XCTAssertNil(update)
    }
}
