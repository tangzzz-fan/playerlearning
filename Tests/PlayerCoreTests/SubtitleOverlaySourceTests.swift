import Foundation
import Testing
@testable import PlayerCore

@Suite
struct SubtitleOverlaySourceTests {
    private static let cues = [
        SubtitleCue(start: 1, end: 3, text: "第一句"),
        SubtitleCue(start: 3, end: 5, text: "第二句")
    ]

    @Test
    func testReturnsTheCueOnScreenAtThatMoment() {
        let source = SubtitleOverlaySource(timeline: SubtitleTimeline(cues: Self.cues))

        #expect(source.text(at: 1.5) == "第一句")
        #expect(source.text(at: 3.5) == "第二句")
    }

    @Test
    func testGapsReturnNilNotEmptyString() {
        // `nil` 与 `""` 在叠加层上是两件事：前者不画，后者会画一条空描边。
        let source = SubtitleOverlaySource(timeline: SubtitleTimeline(cues: Self.cues))

        #expect(source.text(at: 0.5) == nil)
        #expect(source.text(at: 9) == nil)
    }

    @Test
    func testDisabledNeverReturnsTextButKeepsTheTimeline() {
        var source = SubtitleOverlaySource(timeline: SubtitleTimeline(cues: Self.cues))
        source.isEnabled = false

        #expect(source.text(at: 1.5) == nil)
        // 关掉再打开必须立刻有字幕 —— 不重新解析（`isEnabled` 存在的理由）。
        #expect(source.timeline.cues.count == 2)
        #expect(!source.isEmpty)
    }

    @Test
    func testMultiLineCueIsFlattenedToOneLine() {
        // 叠加层一行一画：字符串里带 `\n` 会被 CoreText 当成字形序列，表现为乱码/方块。
        let cue = SubtitleCue(start: 0, end: 10, text: "上一行\n下一行")
        let source = SubtitleOverlaySource(timeline: SubtitleTimeline(cues: [cue]))

        #expect(source.text(at: 1) == "上一行 下一行")
    }

    @Test
    func testOverlappingCuesAreJoinedNotDropped() {
        // ASS 允许两条同时在场。只取一条会**丢内容**，而不是"少显示一点"。
        let cues = [
            SubtitleCue(start: 0, end: 10, text: "底下"),
            SubtitleCue(start: 2, end: 4, text: "上面")
        ]
        let source = SubtitleOverlaySource(timeline: SubtitleTimeline(cues: cues))

        #expect(source.text(at: 3) == "底下 / 上面")
        #expect(source.text(at: 5) == "底下")
    }

    @Test
    func testDelayMovesTheCueForward() {
        // 正数 = 字幕**晚**出现：t=1.5 的查询在 delay=1 时要落到 0.5，即第一句还没开始。
        var source = SubtitleOverlaySource(timeline: SubtitleTimeline(cues: Self.cues))
        source.setDelay(1)

        #expect(source.text(at: 1.5) == nil)
        #expect(source.text(at: 2.5) == "第一句")
    }

    @Test
    func testDelayIsClampedAndMillisecondAligned() {
        var source = SubtitleOverlaySource(timeline: SubtitleTimeline(cues: Self.cues))
        source.setDelay(9999)

        #expect(source.timeline.delay == SubtitleTimeline.delayRange.upperBound)

        source.adjustDelay(by: -0.1)
        #expect(source.timeline.delay == SubtitleTimeline.delayRange.upperBound - 0.1)
    }

    @Test
    func testEmptyTimelineReportsEmpty() {
        let source = SubtitleOverlaySource(timeline: SubtitleTimeline())

        #expect(source.isEmpty)
        #expect(source.text(at: 1) == nil)
    }
}
