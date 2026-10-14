import Foundation

/// 字幕的**跨层状态**：轨道清单 + 当前选择 + 开关 + 延迟。
///
/// 它把「**开关是开的**」与「**确实在显示**」分开 —— 这条规则从 `P3-T3` 的
/// `PlayerSubtitleToggle` 迁过来（那个类型在 `PlayerUI`，因为当时状态还没有来源；
/// 现在状态从内核来，所以上移到 `PlayerCore`，语义原样保留并加强）。
///
/// 为什么要分：`sub-visibility=yes` 只表示"允许显示"，
/// 真正显示还需要**有一条选中的轨**。把这两件事合成一个 bool，
/// 就会出现"字幕开着、界面说在显示、屏幕上一个字都没有"——用户称之为 bug。
public struct PlayerSubtitleState: Sendable, Equatable {
    /// 当前可用的字幕轨（内挂 + 已加载的外挂）。
    public var tracks: [SubtitleTrack]
    /// 选中的轨 id；`nil` = 没有选中任何轨（mpv 的 `sid=no`）。
    public var selectedTrackID: Int64?
    /// 用户要不要字幕（mpv 的 `sub-visibility`）。
    public var isVisible: Bool
    /// 延迟（秒）。**正数 = 字幕晚出现**，与 mpv 的 `sub-delay` 同向。
    public var delay: Double

    public init(
        tracks: [SubtitleTrack] = [],
        selectedTrackID: Int64? = nil,
        isVisible: Bool = false,
        delay: Double = 0
    ) {
        self.tracks = tracks
        self.selectedTrackID = selectedTrackID
        self.isVisible = isVisible
        self.delay = delay
    }

    /// 有没有可显示的字幕源。
    public var hasSource: Bool { !tracks.isEmpty }

    /// **只有"开着 且 选中项能解析到一条真实存在的轨"才算真的在显示。**
    ///
    /// ⚠️ 判据是 `selectedTrack != nil` 而不是 `selectedTrackID != nil` —— 两者**不等价**。
    /// 实测（MPV 包测试）：换文件之后 mpv 的 `sid` **仍指向上一个文件的轨道 id**，
    /// 于是 `selectedTrackID` 非 nil、而 `tracks` 是空的。
    /// 只判 `!= nil` 的话，界面会显示"正在显示字幕"而屏幕上什么都没有 —— 那就是个 bug。
    /// **内核报告的引用型状态（id）不是"对象存在"的证据，必须用清单去解析。**
    public var isDisplaying: Bool { isVisible && selectedTrack != nil }

    public var selectedTrack: SubtitleTrack? {
        guard let selectedTrackID else { return nil }
        return tracks.first { $0.id == selectedTrackID }
    }

    /// 界面上该显示的一行字 —— **四种状态必须可区分**。
    /// （`P3-T3` 时是三种；多出来的第四种是"开着但没选轨"，
    ///   它比"没字幕源"更常见，也更像 bug，所以必须能看出来。）
    public var label: String {
        guard isVisible else { return "字幕：关" }
        guard hasSource else { return "字幕：开（暂无字幕源）" }
        guard let track = selectedTrack else { return "字幕：开（未选轨道）" }
        return "字幕：开 · \(track.label)"
    }

    /// 把延迟对齐到毫秒并钳到合法区间 —— 复用时间线的规则，**不另立一套**。
    public mutating func setDelay(_ seconds: Double) {
        delay = SubtitleTimeline.normalizeDelay(seconds)
    }
}
