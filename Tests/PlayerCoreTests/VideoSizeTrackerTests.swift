import CoreGraphics
import Testing
@testable import PlayerCore

@Suite
struct VideoSizeTrackerTests {
    @Test
    func testInitialSizeIsZero() {
        #expect(VideoSizeTracker().size == .zero)
    }

    @Test
    func testWidthAloneDoesNotProduceSize() {
        var tracker = VideoSizeTracker()

        let produced = tracker.setWidth(1920)

        #expect(produced == nil, "高度未知时不应报尺寸")
        #expect(tracker.size == .zero)
    }

    @Test
    func testHeightAloneDoesNotProduceSize() {
        var tracker = VideoSizeTracker()

        let produced = tracker.setHeight(1080)

        #expect(produced == nil, "宽度未知时不应报尺寸")
        #expect(tracker.size == .zero)
    }

    @Test
    func testWidthThenHeightProducesSize() {
        var tracker = VideoSizeTracker()
        _ = tracker.setWidth(1920)

        let produced = tracker.setHeight(1080)

        #expect(produced == CGSize(width: 1920, height: 1080))
        #expect(tracker.size == CGSize(width: 1920, height: 1080))
    }

    @Test
    func testHeightThenWidthProducesSize() {
        var tracker = VideoSizeTracker()
        _ = tracker.setHeight(1080)

        let produced = tracker.setWidth(1920)

        #expect(produced == CGSize(width: 1920, height: 1080))
    }

    @Test
    func testSameSizeAgainProducesNothing() {
        var tracker = VideoSizeTracker()
        _ = tracker.setWidth(1920)
        _ = tracker.setHeight(1080)

        let produced = tracker.setHeight(1080)

        #expect(produced == nil, "同尺寸不应重复上报")
    }

    @Test
    func testChangingWidthProducesNewSize() {
        var tracker = VideoSizeTracker()
        _ = tracker.setWidth(1920)
        _ = tracker.setHeight(1080)

        let produced = tracker.setWidth(1280)

        #expect(produced == CGSize(width: 1280, height: 1080))
    }

    @Test
    func testZeroDimensionClearsReportedSize() {
        var tracker = VideoSizeTracker()
        _ = tracker.setWidth(1920)
        _ = tracker.setHeight(1080)

        let produced = tracker.setHeight(0)

        #expect(produced == .zero, "切到纯音频时 UI 必须能感知「没有画面了」")
        #expect(tracker.size == .zero)
    }

    @Test
    func testNegativeDimensionIsTreatedAsUnknown() {
        var tracker = VideoSizeTracker()
        _ = tracker.setWidth(1920)

        let produced = tracker.setHeight(-1080)

        #expect(produced == nil, "负值视为未知，且不应把已报的 .zero 再报一次")
        #expect(tracker.size == .zero)
    }

    @Test
    func testZeroWidthClearsReportedSize() {
        var tracker = VideoSizeTracker()
        _ = tracker.setWidth(1920)
        _ = tracker.setHeight(1080)

        let produced = tracker.setWidth(0)

        #expect(produced == .zero)
    }

    @Test
    func testRecoveryAfterClearedSizeProducesSizeAgain() {
        var tracker = VideoSizeTracker()
        _ = tracker.setWidth(1920)
        _ = tracker.setHeight(1080)
        _ = tracker.setHeight(0)

        let produced = tracker.setHeight(1080)

        #expect(produced == CGSize(width: 1920, height: 1080), "清空后恢复画面应重新上报")
    }
}
