import Foundation
import Testing
@testable import PlayerCore
@testable import PlayerUI

@Suite
@MainActor
struct PlayerViewModelLiveTests {
    private func loadedModel(duration: Double) async -> (PlayerViewModel, FakeKernel) {
        let kernel = FakeKernel(duration: duration)
        let model = PlayerViewModel(controller: PlayerController(kernel: kernel))
        await model.start()
        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv")))
        try? await Task.sleep(for: .milliseconds(60))
        return (model, kernel)
    }

    @Test
    func testNewModelIsNotLive() async {
        let (model, _) = await loadedModel(duration: 52.208)

        #expect(model.isLive == false)
    }

    @Test
    func testFixedDurationStaysVOD() async {
        let (model, kernel) = await loadedModel(duration: 52.2)
        await kernel.emit(.durationChanged(52.208))
        await kernel.emit(.currentTimeChanged(10))
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.isLive == false)
    }

    @Test
    func testDurationGrowingAlongWithPlaybackBecomesLive() async {
        let (model, kernel) = await loadedModel(duration: 1.09)

        await kernel.emit(.currentTimeChanged(2.0))
        await kernel.emit(.durationChanged(3.5))
        await kernel.emit(.currentTimeChanged(4.3))
        await kernel.emit(.durationChanged(4.12))
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.isLive == true)
    }

    @Test
    func testLiveFlagSurvivesLaterTimeUpdates() async {
        let (model, kernel) = await loadedModel(duration: 1.09)
        await kernel.emit(.currentTimeChanged(2.0))
        await kernel.emit(.durationChanged(4.12))

        await kernel.emit(.currentTimeChanged(9.0))
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.isLive == true)
    }

    @Test
    func testLoadingAnotherResourceClearsLiveFlag() async {
        let (model, kernel) = await loadedModel(duration: 1.09)
        await kernel.emit(.currentTimeChanged(2.0))
        await kernel.emit(.durationChanged(4.12))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.isLive == true)

        await model.load(PlayerResource(url: URL(fileURLWithPath: "/tmp/other.mkv")))
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.isLive == false)
    }

    @Test
    func testUnknownDurationLiveStreamIsDetected() async {
        let (model, kernel) = await loadedModel(duration: 0)

        await kernel.emit(.currentTimeChanged(2.0))
        await kernel.emit(.currentTimeChanged(5.5))
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.isLive == true)
    }
}
