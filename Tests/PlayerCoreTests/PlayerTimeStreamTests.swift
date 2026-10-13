import Testing
@testable import PlayerCore

@Suite
struct PlayerTimeStreamTests {
    @Test
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
        #expect(first?.currentTime == 0)
        #expect(second?.currentTime == 0.6)
        #expect(third == nil)
    }

    @Test
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
        #expect(first == PlayerTimeUpdate(currentTime: 0, duration: 90))
        #expect(second == PlayerTimeUpdate(currentTime: 1, duration: 90))
        #expect(third == nil)
    }

    @Test
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
        #expect(update == nil)
    }

    @Test
    func testStreamTerminatesWhenEventStreamFinishes() async {
        let kernel = FakeKernel()
        let model = PlayerTimeModel(interval: 0.25)
        let events = await kernel.events()
        var iterator = model.updates(from: events).makeAsyncIterator()

        await kernel.finishEvents()

        let update = await iterator.next()
        #expect(update == nil)
    }
}
