import XCTest
@testable import PlayerCore

final class PlayerTimeModelTests: XCTestCase {
    func testInitialValuesAreZero() {
        let model = PlayerTimeModel()

        XCTAssertEqual(model.currentTime, 0)
        XCTAssertEqual(model.duration, 0)
    }

    func testDefaultIntervalIsQuarterSecond() {
        XCTAssertEqual(PlayerTimeModel().interval, 0.25)
    }

    func testIntervalBelowLowerBoundIsRaised() {
        XCTAssertEqual(PlayerTimeModel(interval: 0).interval, 0.2)
        XCTAssertEqual(PlayerTimeModel(interval: 0.05).interval, 0.2)
    }

    func testIntervalAboveUpperBoundIsLowered() {
        XCTAssertEqual(PlayerTimeModel(interval: 5).interval, 1.0)
    }

    func testIntervalIsExactlyAtLowerBoundIsKept() {
        XCTAssertEqual(PlayerTimeModel(interval: 0.2).interval, 0.2)
    }

    func testFirstTimeEventIsAlwaysPublished() {
        var model = PlayerTimeModel(interval: 0.25)

        let update = model.apply(.currentTimeChanged(0.01))

        XCTAssertEqual(update, PlayerTimeUpdate(currentTime: 0.01, duration: 0))
    }

    func testSmallChangeWithinIntervalIsThrottled() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        XCTAssertNil(model.apply(.currentTimeChanged(0.1)))
    }

    func testChangeExactlyAtIntervalIsPublished() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        XCTAssertEqual(model.apply(.currentTimeChanged(0.25)), PlayerTimeUpdate(currentTime: 0.25, duration: 0))
    }

    func testAccumulatedChangeEventuallyPublishes() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        XCTAssertNil(model.apply(.currentTimeChanged(0.1)))
        XCTAssertNil(model.apply(.currentTimeChanged(0.2)))
        XCTAssertEqual(model.apply(.currentTimeChanged(0.3)), PlayerTimeUpdate(currentTime: 0.3, duration: 0))
    }

    func testCurrentTimeTracksTruthEvenWhileThrottled() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(0))

        _ = model.apply(.currentTimeChanged(0.1))

        XCTAssertEqual(model.currentTime, 0.1)
    }

    func testBackwardJumpBeyondIntervalIsPublished() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(30))

        XCTAssertEqual(model.apply(.currentTimeChanged(5)), PlayerTimeUpdate(currentTime: 5, duration: 0))
    }

    func testBackwardJumpWithinIntervalIsThrottled() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(30))

        XCTAssertNil(model.apply(.currentTimeChanged(29.9)))
    }

    func testDurationEventIsAlwaysPublished() {
        var model = PlayerTimeModel(interval: 0.25)

        let update = model.apply(.durationChanged(120))

        XCTAssertEqual(update, PlayerTimeUpdate(currentTime: 0, duration: 120))
    }

    func testDurationEventUpdatesDuration() {
        var model = PlayerTimeModel(interval: 0.25)

        _ = model.apply(.durationChanged(120))

        XCTAssertEqual(model.duration, 120)
    }

    func testDurationEventIsCarriedOnLaterTimeUpdates() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.durationChanged(120))

        let update = model.apply(.currentTimeChanged(1))

        XCTAssertEqual(update, PlayerTimeUpdate(currentTime: 1, duration: 120))
    }

    func testAnyPublicationResetsThrottleBaseline() {
        var model = PlayerTimeModel(interval: 0.25)
        _ = model.apply(.currentTimeChanged(10))

        _ = model.apply(.durationChanged(100))

        XCTAssertNil(model.apply(.currentTimeChanged(10.1)))
    }

    func testBufferingEventProducesNoUpdate() {
        var model = PlayerTimeModel()

        XCTAssertNil(model.apply(.bufferingChanged(true)))
    }

    func testStateChangeProducesNoUpdate() {
        var model = PlayerTimeModel()

        XCTAssertNil(model.apply(.stateChanged(.playing)))
    }

    func testNegativeDurationIsTreatedAsUnknown() {
        var model = PlayerTimeModel()

        _ = model.apply(.durationChanged(-10))

        XCTAssertEqual(model.duration, 0)
    }

    func testNonFiniteDurationIsTreatedAsUnknown() {
        var model = PlayerTimeModel()

        _ = model.apply(.durationChanged(.nan))

        XCTAssertEqual(model.duration, 0)
    }

    func testClampKeepsValueInsideRange() {
        let model = PlayerTimeModel(duration: 100)

        XCTAssertEqual(model.clampSeekTarget(42), 42)
    }

    func testClampRaisesNegativeToZero() {
        let model = PlayerTimeModel(duration: 100)

        XCTAssertEqual(model.clampSeekTarget(-5), 0)
    }

    func testClampLowersValueBeyondDuration() {
        let model = PlayerTimeModel(duration: 100)

        XCTAssertEqual(model.clampSeekTarget(999), 100)
    }

    func testClampKeepsExactUpperBound() {
        let model = PlayerTimeModel(duration: 100)

        XCTAssertEqual(model.clampSeekTarget(100), 100)
    }

    func testClampWithUnknownDurationKeepsLowerBoundOnly() {
        let model = PlayerTimeModel(duration: 0)

        XCTAssertEqual(model.clampSeekTarget(42), 42)
    }

    func testClampWithUnknownDurationStillRaisesNegativeToZero() {
        let model = PlayerTimeModel(duration: 0)

        XCTAssertEqual(model.clampSeekTarget(-1), 0)
    }

    func testClampTreatsNaNAsZero() {
        var model = PlayerTimeModel(duration: 100)
        _ = model.apply(.currentTimeChanged(30))

        XCTAssertEqual(model.clampSeekTarget(.nan), 0)
    }

    func testClampTreatsPositiveInfinityAsDuration() {
        let model = PlayerTimeModel(duration: 100)

        XCTAssertEqual(model.clampSeekTarget(.infinity), 100)
    }

    func testClampTreatsPositiveInfinityAsZeroWhenDurationUnknown() {
        let model = PlayerTimeModel(duration: 0)

        XCTAssertEqual(model.clampSeekTarget(.infinity), 0)
    }

    func testClampTreatsNegativeInfinityAsZero() {
        let model = PlayerTimeModel(duration: 100)

        XCTAssertEqual(model.clampSeekTarget(-.infinity), 0)
    }
}
