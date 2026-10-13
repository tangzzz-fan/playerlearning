import Foundation

/// 一条字幕（cue）：一个**左闭右开**的时间窗 + 纯文本。
public struct SubtitleCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// 来自 ASS 的样式名；SRT 没有这个概念，为 `nil`。
    public var styleName: String?

    public init(start: Double, end: Double, text: String, styleName: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.styleName = styleName
    }

    public var duration: Double { Swift.max(0, end - start) }

    /// 时间窗是否覆盖某时刻。
    ///
    /// **左闭右开是刻意的**：相邻两条在接缝处（前一条 `end` == 后一条 `start`）只命中后一条。
    /// 若两端都闭，接缝上会同时命中两条，UI 表现为"闪回上一条"——
    /// 而这种抖动在 60 fps 下只有一两帧，靠眼睛很难定位，只能靠约定堵死。
    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }
}
