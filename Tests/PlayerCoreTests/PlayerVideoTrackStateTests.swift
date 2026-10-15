import Testing

@testable import PlayerCore

/// `PlayerVideoTrackState` / `VideoTrack` 的**纯逻辑**测试。
///
/// 这些行为不依赖 mpv：它们是"档位清单怎么呈现给界面"的规则，
/// 所以放在 `PlayerCore`（可测、零 I/O）而不是内核包里。
@Suite
struct PlayerVideoTrackStateTests {
    private func track(
        id: Int64,
        width: Int = 1280,
        height: Int = 720,
        codec: String? = "h264",
        bitrate: Int? = nil
    ) -> VideoTrack {
        VideoTrack(id: id, width: width, height: height, codec: codec, bitrate: bitrate)
    }

    // MARK: - label

    @Test
    func testLabelIsResolutionWhenBitrateUnknown() {
        #expect(track(id: 1).label == "1280×720")
    }

    @Test
    func testLabelAppendsBitrateWhenKnown() {
        // 2284533 bit/s → 2.3 Mbps（保留一位小数：档位差距远大于 0.1）
        #expect(track(id: 1, bitrate: 2_284_533).label == "1280×720 · 2.3 Mbps")
    }

    @Test
    func testLabelIgnoresNonPositiveBitrate() {
        // 0 / 负数是"读到了但没意义"，与"读不到"一样处理 —— 不要显示 "· 0.0 Mbps"
        #expect(track(id: 1, bitrate: 0).label == "1280×720")
        #expect(track(id: 1, bitrate: -1).label == "1280×720")
    }

    /// 分辨率读不到时才退回带 id 的兜底 —— 与 `SubtitleTrack.label` 同一条规则：
    /// **两条兜底长得一样，用户就没法选**，所以兜底必须带上可区分的东西。
    @Test
    func testLabelFallsBackToIDWhenResolutionUnknown() {
        #expect(track(id: 7, width: 0, height: 0).label == "视频轨 #7")
        #expect(track(id: 7, width: 1280, height: 0).label == "视频轨 #7")
    }

    // MARK: - hasAlternatives

    @Test
    func testNoTracksAndSingleTrackHaveNoAlternatives() {
        #expect(PlayerVideoTrackState().hasAlternatives == false)
        #expect(PlayerVideoTrackState(tracks: [track(id: 1)]).hasAlternatives == false)
    }

    @Test
    func testTwoTracksHaveAlternatives() {
        let state = PlayerVideoTrackState(tracks: [track(id: 1), track(id: 2, width: 854, height: 480)])
        #expect(state.hasAlternatives)
    }

    // MARK: - 选中项解析

    @Test
    func testSelectedTrackIsResolvedThroughTheList() {
        let state = PlayerVideoTrackState(
            tracks: [track(id: 1), track(id: 2, width: 854, height: 480)],
            selectedTrackID: 2
        )
        #expect(state.selectedTrack?.width == 854)
        #expect(state.label == "清晰度：854×480")
    }

    /// ⚠️ **核心教训（与 `PlayerSubtitleState` 同源）**：
    /// `selectedTrackID` 非 nil **不等于**"选中了一条真实存在的轨"。
    /// 换文件之后 mpv 的 `vid` 仍可能指向上一个文件的 id ——
    /// 只判 `!= nil` 的界面会显示一个**实际并不存在**的档位。
    @Test
    func testDanglingSelectedIDResolvesToNil() {
        let state = PlayerVideoTrackState(tracks: [track(id: 1)], selectedTrackID: 99)
        #expect(state.selectedTrack == nil)
        #expect(state.label == "清晰度：—")
    }

    @Test
    func testNoSelectionShowsDash() {
        #expect(PlayerVideoTrackState(tracks: [track(id: 1)]).label == "清晰度：—")
    }
}
