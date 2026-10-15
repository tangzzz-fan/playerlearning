import CoreGraphics
import Testing
@testable import PlayerCore

@Suite
struct PlayerTimeModelTests {
    @Test
    func testInitialValuesAreZero() {
        let model = PlayerTimeModel()

        #expect(model.currentTime == 0)
        #expect(model.duration == 0)
    }

    @Test
    func testDefaultIntervalIsQuarterSecond() {
        #expect(PlayerTimeModel().interval == 0.25)
    }

    @Test
    func testIntervalBelowLowerBoundIsRaised() {
        #expect(PlayerTimeModel(interval: 0).interval == 0.2)
        #expect(PlayerTimeModel(interval: 0.05).interval == 0.2)
    }

    @Test
    func testIntervalAboveUpperBoundIsLowered() {
        #expect(PlayerTimeModel(interval: 5).interval == 1.0)
    }

    @Test
    func testIntervalIsExactlyAtLowerBoundIsKept() {
        #expect(PlayerTimeModel(interval: 0.2).interval == 0.2)
    }

    @Test
    func testFirstTimeEventIsAlwaysPublished() {
        var model = PlayerTimeModel(interval: 0.25)

        let update = model.apply(.currentTimeChanged(0.01))

        #expect(update == PlayerTimeUpdate(currentTime: 0.01, duration: 0))
    }

    @Test
    func testSmallChangeWithinIntervalIsThrottled() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        let update = model.apply(.currentTimeChanged(0.1))

        #expect(update == nil)
    }

    @Test
    func testChangeExactlyAtIntervalIsPublished() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        let update = model.apply(.currentTimeChanged(0.25))

        #expect(update == PlayerTimeUpdate(currentTime: 0.25, duration: 0))
    }

    @Test
    func testAccumulatedChangeEventuallyPublishes() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        let first = model.apply(.currentTimeChanged(0.1))
        let second = model.apply(.currentTimeChanged(0.2))
        let third = model.apply(.currentTimeChanged(0.3))

        #expect(first == nil)
        #expect(second == nil)
        #expect(third == PlayerTimeUpdate(currentTime: 0.3, duration: 0))
    }

    @Test
    func testCurrentTimeTracksTruthEvenWhileThrottled() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        _ = model.apply(.currentTimeChanged(0.1))

        #expect(model.currentTime == 0.1)
    }

    @Test
    func testBackwardJumpBeyondIntervalIsPublished() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(30))

        let update = model.apply(.currentTimeChanged(5))

        #expect(update == PlayerTimeUpdate(currentTime: 5, duration: 0))
    }

    @Test
    func testBackwardJumpWithinIntervalIsThrottled() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(30))

        let update = model.apply(.currentTimeChanged(29.9))

        #expect(update == nil)
    }

    @Test
    func testDurationEventIsAlwaysPublished() {
        var model = PlayerTimeModel(interval: 0.25)

        let update = model.apply(.durationChanged(120))

        #expect(update == PlayerTimeUpdate(currentTime: 0, duration: 120))
    }

    @Test
    func testDurationEventUpdatesDuration() {
        var model = PlayerTimeModel(interval: 0.25)

        _ = model.apply(.durationChanged(120))

        #expect(model.duration == 120)
    }

    @Test
    func testDurationEventIsCarriedOnLaterTimeUpdates() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.durationChanged(120))

        let update = model.apply(.currentTimeChanged(1))

        #expect(update == PlayerTimeUpdate(currentTime: 1, duration: 120))
    }

    @Test
    func testAnyPublicationResetsThrottleBaseline() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(10))

        _ = model.apply(.durationChanged(100))

        let update = model.apply(.currentTimeChanged(10.1))

        #expect(update == nil)
    }

    @Test
    func testBufferingEventProducesNoUpdate() {
        var model = PlayerTimeModel()

        let update = model.apply(.bufferingChanged(true))

        #expect(update == nil)
    }

    @Test
    func testStateChangeProducesNoUpdate() {
        var model = PlayerTimeModel()

        let update = model.apply(.stateChanged(.playing))

        #expect(update == nil)
    }

    @Test
    func testVideoSizeEventProducesNoUpdate() {
        var model = PlayerTimeModel()

        let update = model.apply(.videoSizeChanged(CGSize(width: 1920, height: 1080)))

        #expect(update == nil)
    }

    @Test
    func testNegativeDurationIsTreatedAsUnknown() {
        var model = PlayerTimeModel()

        _ = model.apply(.durationChanged(-10))

        #expect(model.duration == 0)
    }

    @Test
    func testNonFiniteDurationIsTreatedAsUnknown() {
        var model = PlayerTimeModel()

        _ = model.apply(.durationChanged(.nan))

        #expect(model.duration == 0)
    }

    @Test
    func testClampKeepsValueInsideRange() {
        let model = PlayerTimeModel(duration: 100)

        #expect(model.clampSeekTarget(42) == 42)
    }

    @Test
    func testClampRaisesNegativeToZero() {
        let model = PlayerTimeModel(duration: 100)

        #expect(model.clampSeekTarget(-5) == 0)
    }

    @Test
    func testClampLowersValueBeyondDuration() {
        let model = PlayerTimeModel(duration: 100)

        #expect(model.clampSeekTarget(999) == 100)
    }

    @Test
    func testClampKeepsExactUpperBound() {
        let model = PlayerTimeModel(duration: 100)

        #expect(model.clampSeekTarget(100) == 100)
    }

    @Test
    func testClampWithUnknownDurationKeepsLowerBoundOnly() {
        let model = PlayerTimeModel(duration: 0)

        #expect(model.clampSeekTarget(42) == 42)
    }

    @Test
    func testClampWithUnknownDurationStillRaisesNegativeToZero() {
        let model = PlayerTimeModel(duration: 0)

        #expect(model.clampSeekTarget(-1) == 0)
    }

    @Test
    func testClampTreatsNaNAsZero() {
        var model = PlayerTimeModel(duration: 100)
        _ = model.apply(.currentTimeChanged(30))

        #expect(model.clampSeekTarget(.nan) == 0)
    }

    @Test
    func testClampTreatsPositiveInfinityAsDuration() {
        let model = PlayerTimeModel(duration: 100)

        #expect(model.clampSeekTarget(.infinity) == 100)
    }

    @Test
    func testClampTreatsPositiveInfinityAsZeroWhenDurationUnknown() {
        let model = PlayerTimeModel(duration: 0)

        #expect(model.clampSeekTarget(.infinity) == 0)
    }

    @Test
    func testClampTreatsNegativeInfinityAsZero() {
        let model = PlayerTimeModel(duration: 100)

        #expect(model.clampSeekTarget(-.infinity) == 0)
    }

    @Test
    func testSnapToEndMovesPositionToDuration() {
        var model = PlayerTimeModel(duration: 52.208)
        _ = model.apply(.currentTimeChanged(51.9))

        let update = model.snapToEnd()

        #expect(update == PlayerTimeUpdate(currentTime: 52.208, duration: 52.208))
        #expect(model.currentTime == 52.208)
    }

    @Test
    func testSnapToEndIsNoOpWhenDurationUnknown() {
        var model = PlayerTimeModel(duration: 0)
        _ = model.apply(.currentTimeChanged(3))

        #expect(model.snapToEnd() == nil)
        #expect(model.currentTime == 3)
    }

    @Test
    func testSnapToEndIsNoOpWhenAlreadyAtEnd() {
        var model = PlayerTimeModel(duration: 10)
        _ = model.apply(.currentTimeChanged(10))

        #expect(model.snapToEnd() == nil)
    }
}
