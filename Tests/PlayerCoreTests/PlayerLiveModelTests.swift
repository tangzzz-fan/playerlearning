import Testing
@testable import PlayerCore

@Suite
struct PlayerLiveModelTests {
    @Test
    func testStartsNotLive() {
        #expect(PlayerLiveModel().isLive == false)
    }

    @Test
    func testFirstKnownDurationIsNotLive() {
        var model = PlayerLiveModel()

        model.observe(duration: 0, currentTime: 0)
        model.observe(duration: 52.208, currentTime: 0)

        #expect(model.isLive == false)
    }

    @Test
    func testTinyDurationCorrectionIsNotLive() {
        var model = PlayerLiveModel()
        model.observe(duration: 52.2, currentTime: 0)

        model.observe(duration: 52.208, currentTime: 10)

        #expect(model.isLive == false)
    }

    @Test
    func testDurationFractionReportedBeforeRealOneIsNotLive() {
        var model = PlayerLiveModel()
        model.observe(duration: 0.5, currentTime: 0)

        model.observe(duration: 52.208, currentTime: 0)

        #expect(model.isLive == false)
    }

    @Test
    func testDurationGrowingWhileTimeStaysPutIsNotLive() {
        var model = PlayerLiveModel()
        model.observe(duration: 10, currentTime: 0)

        model.observe(duration: 60, currentTime: 0.1)

        #expect(model.isLive == false)
    }

    @Test
    func testDurationGrowingWithPlaybackBecomesLive() {
        var model = PlayerLiveModel()
        model.observe(duration: 1.09, currentTime: 0)

        model.observe(duration: 2.80, currentTime: 3.29)
        model.observe(duration: 4.12, currentTime: 4.33)

        #expect(model.isLive == true)
    }

    @Test
    func testGrowthBelowThresholdIsNotLive() {
        var model = PlayerLiveModel()
        model.observe(duration: 1.09, currentTime: 0)

        model.observe(duration: 2.07, currentTime: 2.23)

        #expect(model.isLive == false)
    }

    @Test
    func testUnknownDurationWithAdvancingTimeIsLive() {
        var model = PlayerLiveModel()

        model.observe(duration: 0, currentTime: 2.0)
        model.observe(duration: 0, currentTime: 5.5)

        #expect(model.isLive == true)
    }

    @Test
    func testUnknownDurationBeforeWindowClosesIsNotLive() {
        var model = PlayerLiveModel()

        model.observe(duration: 0, currentTime: 2.0)
        model.observe(duration: 0, currentTime: 4.9)

        #expect(model.isLive == false)
    }

    @Test
    func testUnknownDurationBeforePlaybackIsNotLive() {
        var model = PlayerLiveModel()

        model.observe(duration: 0, currentTime: 0)

        #expect(model.isLive == false)
    }

    @Test
    func testKnownDurationCancelsUnknownDurationWindow() {
        var model = PlayerLiveModel()
        model.observe(duration: 0, currentTime: 1.0)

        model.observe(duration: 52.208, currentTime: 9.0)
        model.observe(duration: 0, currentTime: 9.5)
        model.observe(duration: 0, currentTime: 12.0)

        #expect(model.isLive == false)
    }

    @Test
    func testLiveSurvivesDurationThatStopsGrowing() {
        var model = PlayerLiveModel()
        model.observe(duration: 1.09, currentTime: 0)
        model.observe(duration: 4.12, currentTime: 4.33)

        model.observe(duration: 4.12, currentTime: 8.0)

        #expect(model.isLive == true)
    }

    @Test
    func testLiveSurvivesDurationFallingBackToUnknown() {
        var model = PlayerLiveModel()
        model.observe(duration: 1.09, currentTime: 0)
        model.observe(duration: 4.12, currentTime: 4.33)

        model.observe(duration: 0, currentTime: 0)

        #expect(model.isLive == true)
    }

    @Test
    func testNonFiniteDurationIsTreatedAsUnknown() {
        var model = PlayerLiveModel()

        model.observe(duration: .nan, currentTime: 2.0)
        model.observe(duration: .nan, currentTime: 6.0)

        #expect(model.isLive == true)
    }

    @Test
    func testGrowthThresholdIsTwoSeconds() {
        #expect(PlayerLiveModel.growthThreshold == 2.0)
    }

    @Test
    func testElapsedRequiredIsOneSecond() {
        #expect(PlayerLiveModel.elapsedRequired == 1.0)
    }

    @Test
    func testUnknownDurationWindowIsThreeSeconds() {
        #expect(PlayerLiveModel.unknownDurationSeconds == 3.0)
    }

    @Test
    func testTimeUpdateCarriesLiveFlag() {
        var time = PlayerTimeModel()

        let update = time.apply(.durationChanged(42.16))

        #expect(update?.isLive == false)
    }

    @Test
    func testTimeModelReportsLiveOnceDurationOutgrowsBaseline() {
        var time = PlayerTimeModel()
        _ = time.apply(.durationChanged(1.09))
        _ = time.apply(.currentTimeChanged(1.0))

        let update = time.apply(.durationChanged(4.12))

        #expect(update?.isLive == true)
    }
}
