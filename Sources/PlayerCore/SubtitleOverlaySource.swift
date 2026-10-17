import Foundation

/// **自绘字幕的数据源**：把"哪一刻该显示哪句话"从播放器里独立出来。
///
/// 与 mpv 那条路的区别（这是 `P7-T3` 的整个动机）：
/// - mpv 自己画字幕时，字幕是**烧进帧里**的 —— 我们的着色器、叠加层、滤镜都碰不到它；
/// - 走这里，文本先到我们手上，再由图层的拥有者自己画（`MPVRenderOutput.overlayText`）。
///
/// 它**不认识 mpv，也不认识图层**：给一个播放时刻，回一段文本。因此可被单测覆盖。
///
/// 为什么要有 `isEnabled` 这一层，而不是直接把 timeline 设成空：
/// 关字幕不该丢掉已解析的内容 —— 用户再打开时应该**立刻**有字幕，
/// 而不是重新解析一遍（外挂字幕常见于几百 KB 的 ASS，重解析肉眼可见）。
public struct SubtitleOverlaySource: Sendable, Equatable {
    public var timeline: SubtitleTimeline
    /// 用户要不要看到自绘字幕。`false` 时 `text(at:)` 恒为 `nil`，但 `timeline` 保留。
    public var isEnabled: Bool

    public init(timeline: SubtitleTimeline = SubtitleTimeline(), isEnabled: Bool = true) {
        self.timeline = timeline
        self.isEnabled = isEnabled
    }

    /// 这一段有没有内容可画（`.srt` 解析出 0 条时是 `false`）。
    public var isEmpty: Bool { timeline.cues.isEmpty }

    /// 该时刻要画的一行（多条重叠按序拼接，换行分隔）。
    public func text(at time: Double) -> String? {
        guard isEnabled else { return nil }
        // 单行化：叠加层是 CoreText 一行一画，带 `\n` 的字符串会被库当成一个字形序列，
        // 表现是"字幕变成方块/乱码"。多条重叠时用 " / " 拼起来 —— 这是**显示层的选择**，
        // 不是数据层的语义（`activeCues` 仍然返回列表）。
        let joined = timeline.activeCues(at: time)
            .map { $0.text.split(whereSeparator: \.isNewline).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        return joined.isEmpty ? nil : joined
    }

    /// 延迟（正数 = 字幕**晚**出现）。与 `SubtitleTimeline` 同一套钳位与毫秒对齐规则。
    public mutating func setDelay(_ seconds: Double) {
        timeline.setDelay(seconds)
    }

    public mutating func adjustDelay(by delta: Double) {
        timeline.adjustDelay(by: delta)
    }
}
