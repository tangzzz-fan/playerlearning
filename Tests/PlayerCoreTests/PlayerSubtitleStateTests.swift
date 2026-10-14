import Foundation
import Testing
@testable import PlayerCore

/// 字幕状态的语义测试。
///
/// 这几条**从 `P3-T3` 的 `PlayerSubtitleToggle` 迁过来**（那个类型在 `PlayerUI`，
/// 因为当时状态还没有来源；现在状态从内核来，类型上移到 `PlayerCore`）。
/// 迁移时语义**原样保留**：核心那条是「**开关 ≠ 生效**」。
/// 唯一增强：多出第四种状态「开着但没选轨道」—— 它比"没字幕源"更常见，也更像 bug，
/// 界面必须能看出区别。
@Suite
struct PlayerSubtitleStateTests {
    @Test
    func testStartsOffAndSilent() {
        let state = PlayerSubtitleState()

        #expect(!state.isVisible)
        #expect(!state.hasSource)
        #expect(!state.isDisplaying)
        #expect(state.label == "字幕：关")
    }

    /// ⚠️ **本类型存在的核心理由**：开关打开 **不等于** 正在显示字幕。
    @Test
    func testVisibleWithoutSourceDoesNotPretendToDisplay() {
        let state = PlayerSubtitleState(isVisible: true)

        #expect(!state.isDisplaying, "没有字幕源 ⇒ 不能说正在显示")
        #expect(state.label == "字幕：开（暂无字幕源）", "必须如实区分「开着但没源」")
    }

    /// 第四种状态：**有源、开着，但没选中任何轨**。
    /// 这正是 mpv 的 `sub-visibility=yes` + `sid=no` —— 屏幕上什么都没有。
    @Test
    func testVisibleWithSourceButNoSelectionDoesNotDisplay() {
        let state = PlayerSubtitleState(
            tracks: [SubtitleTrack(id: 1, title: "中文")],
            selectedTrackID: nil,
            isVisible: true
        )

        #expect(state.hasSource)
        #expect(!state.isDisplaying, "没选中轨道 ⇒ 屏上不会出现字幕")
        #expect(state.label == "字幕：开（未选轨道）")
    }

    @Test
    func testDisplaysOnlyWhenVisibleAndSelected() {
        let track = SubtitleTrack(id: 7, title: "中文", language: "zh", isExternal: true)
        let state = PlayerSubtitleState(tracks: [track], selectedTrackID: 7, isVisible: true)

        #expect(state.isDisplaying)
        #expect(state.label == "字幕：开 · 中文")
    }

    @Test
    func testTurningOffHidesEvenWithSelectedTrack() {
        let track = SubtitleTrack(id: 7, title: "中文")
        let state = PlayerSubtitleState(tracks: [track], selectedTrackID: 7, isVisible: false)

        #expect(!state.isDisplaying)
        #expect(state.label == "字幕：关")
    }

    /// ⚠️ **陈旧 id**：`sid` 非 nil，但清单里没有这条轨（换文件后的真实情形）。
    /// 这时绝不能报告"正在显示" —— 界面上会变成"说在显示、屏上一个字没有"。
    @Test
    func testStaleSelectionIDDoesNotCountAsDisplaying() {
        let state = PlayerSubtitleState(tracks: [], selectedTrackID: 7, isVisible: true)

        #expect(!state.hasSource)
        #expect(state.selectedTrack == nil, "id 解析不到轨道 ⇒ selectedTrack 必须是 nil")
        #expect(!state.isDisplaying, "只看 `selectedTrackID != nil` 就会在这里说谎")
        #expect(state.label == "字幕：开（暂无字幕源）", "真实原因是**没有源**，不是没选轨道")
    }

    @Test
    func testSelectedTrackIsResolvedByID() {
        let tracks = [SubtitleTrack(id: 1, title: "中"), SubtitleTrack(id: 2, title: "英")]

        #expect(PlayerSubtitleState(tracks: tracks, selectedTrackID: 2).selectedTrack?.title == "英")
        #expect(PlayerSubtitleState(tracks: tracks, selectedTrackID: 99).selectedTrack == nil)
        #expect(PlayerSubtitleState(tracks: tracks, selectedTrackID: nil).selectedTrack == nil)
    }

    // MARK: - 轨道标签的三级回退

    @Test
    func testTrackLabelPrefersTitle() {
        #expect(SubtitleTrack(id: 3, title: "中文字幕", language: "zh").label == "中文字幕")
    }

    @Test
    func testTrackLabelFallsBackToLanguage() {
        #expect(SubtitleTrack(id: 3, title: "", language: "zh").label == "zh")
        #expect(SubtitleTrack(id: 3, language: "en").label == "en")
    }

    /// ⚠️ 兜底**必须带 id**：两条无名轨在菜单里长得一模一样，用户就没法选。
    @Test
    func testTrackLabelFallbackIsDistinguishable() {
        let external = SubtitleTrack(id: 5, isExternal: true).label
        let internalTrack = SubtitleTrack(id: 6).label

        #expect(external == "外挂字幕 #5")
        #expect(internalTrack == "字幕轨 #6")
        #expect(external != internalTrack)
    }

    // MARK: - 延迟：与时间线同一套规则

    @Test
    func testDelayIsClampedAndRoundedLikeTimeline() {
        var state = PlayerSubtitleState()

        state.setDelay(9999)
        #expect(state.delay == SubtitleTimeline.delayRange.upperBound)

        state.setDelay(.nan)
        #expect(state.delay == 0)

        state.setDelay(0.0012345)
        #expect(state.delay == 0.001, "对齐到毫秒，避免 ±0.1 累积成 0.30000000000000004")
    }

    /// 延迟规则**只有一处实现**（`SubtitleTimeline.normalizeDelay`）——
    /// 这条测试就是在钉住"两处不各写一套"。
    @Test
    func testDelayRuleIsSharedWithTimeline() {
        for value in [0.0, 1.2345, -0.5, 100.0, -100.0, Double.nan] {
            var state = PlayerSubtitleState()
            state.setDelay(value)
            #expect(state.delay == SubtitleTimeline.normalizeDelay(value))
        }
    }
}
