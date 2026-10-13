import Foundation
import Testing
@testable import PlayerCore

@Suite
struct SubtitleCueTests {
    /// **左闭右开**是与内核时间轴对齐的关键约定：
    /// 相邻两条在接缝处（前一条 `end` == 后一条 `start`）只能命中后一条，
    /// 否则接缝上会同时命中两条，UI 表现为"闪回上一条"。
    @Test
    func testContainsIsLeftClosedRightOpen() {
        let cue = SubtitleCue(start: 1.0, end: 2.0, text: "x")

        #expect(cue.contains(1.0), "起点包含")
        #expect(cue.contains(1.999))
        #expect(!cue.contains(2.0), "终点不包含 —— 交给下一条")
        #expect(!cue.contains(0.999))
    }

    @Test
    func testZeroLengthCueContainsNothing() {
        let cue = SubtitleCue(start: 1.0, end: 1.0, text: "x")

        #expect(!cue.contains(1.0))
    }

    @Test
    func testDurationIsNeverNegative() {
        #expect(SubtitleCue(start: 3, end: 1, text: "x").duration == 0)
        #expect(SubtitleCue(start: 1, end: 3, text: "x").duration == 2)
    }
}

@Suite
struct SubtitleTimelineTests {
    private static let cues = [
        SubtitleCue(start: 0, end: 1, text: "一"),
        SubtitleCue(start: 1, end: 2, text: "二"),
        SubtitleCue(start: 4, end: 5, text: "三"),
    ]

    @Test
    func testFindsCueAtTime() {
        let timeline = SubtitleTimeline(cues: Self.cues)

        #expect(timeline.cue(at: 0.5)?.text == "一")
        #expect(timeline.cue(at: 1.5)?.text == "二")
        #expect(timeline.cue(at: 4.5)?.text == "三")
    }

    @Test
    func testSeamHitsOnlyTheLaterCue() {
        let timeline = SubtitleTimeline(cues: Self.cues)

        #expect(timeline.cue(at: 1.0)?.text == "二", "接缝处只应命中后一条")
    }

    @Test
    func testGapsAndEdgesHaveNoCue() {
        let timeline = SubtitleTimeline(cues: Self.cues)

        #expect(timeline.cue(at: 2.0) == nil, "末点不包含")
        #expect(timeline.cue(at: 3.0) == nil, "空隙无字幕")
        #expect(timeline.cue(at: 5.0) == nil)
        #expect(timeline.cue(at: -1) == nil)
    }

    @Test
    func testSearchesAcrossUnsortedInput() {
        let timeline = SubtitleTimeline(cues: Self.cues.reversed())

        #expect(timeline.cue(at: 1.5)?.text == "二")
    }

    // MARK: - 延迟（G4 的「字幕延迟可调」）

    @Test
    func testPositiveDelayPushesSubtitlesLater() {
        // 「延迟 +0.5 s」= 字幕晚 0.5 s 出现：
        //   原本 0.0–1.0 的那条 → 0.5–1.5；原本 1.0–2.0 的 → 1.5–2.5。
        let timeline = SubtitleTimeline(cues: Self.cues, delay: 0.5)

        #expect(timeline.cue(at: 0.4) == nil, "还没到它该出现的时候")
        #expect(timeline.cue(at: 0.6)?.text == "一", "0.5 之后才轮到第一条")
        #expect(timeline.cue(at: 1.2)?.text == "一", "被推后 ⇒ 1.2 时仍在放第一条")
        #expect(timeline.cue(at: 1.7)?.text == "二", "第二条要到 1.5 之后")
    }

    @Test
    func testNegativeDelayPullsSubtitlesEarlier() {
        let timeline = SubtitleTimeline(cues: Self.cues, delay: -0.5)

        #expect(timeline.cue(at: 0.6)?.text == "二", "0.5 时已经在放原本 1.0 起的那条")
        #expect(timeline.cue(at: 1.6) == nil, "原本 1.0–2.0 的已提前结束")
    }

    @Test
    func testDelayIsClampedToRange() {
        let tooBig = SubtitleTimeline(cues: Self.cues, delay: 9999)
        let tooSmall = SubtitleTimeline(cues: Self.cues, delay: -9999)

        #expect(tooBig.delay == SubtitleTimeline.delayRange.upperBound)
        #expect(tooSmall.delay == SubtitleTimeline.delayRange.lowerBound)
    }

    @Test
    func testNonFiniteDelayBecomesZero() {
        #expect(SubtitleTimeline(cues: [], delay: .nan).delay == 0)
        #expect(SubtitleTimeline(cues: [], delay: .infinity).delay == 0)
    }

    /// 延迟会被反复 ±0.1 地调，浮点累加会攒出 `0.30000000000000004` 这种值；
    /// 落到毫秒精度既避免噪声，也让显示与内核回读一致。
    @Test
    func testDelayIsRoundedToMilliseconds() {
        var timeline = SubtitleTimeline()

        for _ in 0 ..< 3 {
            timeline.adjustDelay(by: 0.1)
        }

        #expect(timeline.delay == 0.3, "三次 +0.1 必须正好是 0.3，实测 \(timeline.delay)")
    }

    @Test
    func testAdjustDelayAccumulatesAndClamps() {
        var timeline = SubtitleTimeline()

        timeline.adjustDelay(by: -2)
        #expect(timeline.delay == -2)

        timeline.setDelay(SubtitleTimeline.delayRange.upperBound + 5)
        #expect(timeline.delay == SubtitleTimeline.delayRange.upperBound)
    }

    @Test
    func testReplacingCuesKeepsDelay() {
        var timeline = SubtitleTimeline(cues: Self.cues, delay: 1.25)

        timeline.replace(cues: [SubtitleCue(start: 10, end: 11, text: "新")])

        #expect(timeline.delay == 1.25, "换文件不该把用户调好的延迟丢掉")
        // 延迟仍在生效 ⇒ 新内容也要整体后移 1.25 s。
        #expect(timeline.cue(at: 10.5) == nil, "10.5 时它还没轮到（被 1.25 s 延迟推后）")
        #expect(timeline.cue(at: 11.5)?.text == "新")
    }

    // MARK: - 重叠（ASS 天然允许两条同时显示）

    @Test
    func testOverlappingCuesAreBothActive() {
        let overlapping = [
            SubtitleCue(start: 0, end: 5, text: "上"),
            SubtitleCue(start: 1, end: 2, text: "下"),
        ]
        let timeline = SubtitleTimeline(cues: overlapping)

        #expect(timeline.activeCues(at: 1.5).map(\.text) == ["上", "下"])
        #expect(timeline.cue(at: 1.5)?.text == "下", "取最上面那条")
        #expect(timeline.text(at: 1.5) == "上\n下")
        #expect(timeline.activeCues(at: 3).count == 1)
    }

    @Test
    func testTextIsNilWhenNothingIsActive() {
        let timeline = SubtitleTimeline(cues: Self.cues)

        #expect(timeline.text(at: 3) == nil)
    }

    /// 倒序输入 + 重叠：二分查找依赖"按 start 有序 + 最长时长"这条不变量，
    /// 这里专门用**乱序的重叠集合**压一下它。
    @Test
    func testBinarySearchHandlesUnsortedOverlaps() {
        let messy = [
            SubtitleCue(start: 6, end: 9, text: "长"),
            SubtitleCue(start: 1, end: 2, text: "短"),
            SubtitleCue(start: 7, end: 8, text: "中"),
        ]
        let timeline = SubtitleTimeline(cues: messy)

        #expect(timeline.activeCues(at: 7.5).map(\.text) == ["长", "中"])
        #expect(timeline.activeCues(at: 3).isEmpty)
    }
}
