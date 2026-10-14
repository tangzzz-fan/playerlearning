import Foundation

/// 字幕时间线：**按播放时刻查当前该显示什么**。
///
/// 三件事刻意做在这里，而不是散在界面代码里：
/// ① 排序不变量（查询用二分，必须有序）；
/// ② 延迟偏移（`G4` 的「字幕延迟可调」）；
/// ③ 重叠语义（ASS 天然允许两条同时在场，取"最上面那条"）。
///
/// 它**不认识 mpv、也不认识播放器**：给一个时间，回一个答案。因此可被门禁单测与变异覆盖。
public struct SubtitleTimeline: Sendable, Equatable {
    /// 延迟的可调范围（秒）。做成常量而不是散落的字面量，测试与界面读同一处。
    public static let delayRange: ClosedRange<Double> = -60 ... 60

    public private(set) var cues: [SubtitleCue]
    /// 正数 = 字幕**晚**出现（与 mpv 的 `sub-delay` 同向）。
    public private(set) var delay: Double

    /// 最长的一条有多长 —— 二分找到候选区间后，用它决定**还要往回看多远**。
    /// 没有这个上界，重叠字幕会让回看退化成全表扫描。
    private var longestDuration: Double

    public init(cues: [SubtitleCue] = [], delay: Double = 0) {
        let sorted = Self.sorted(cues)
        self.cues = sorted
        self.delay = Self.normalizeDelay(delay)
        longestDuration = sorted.map(\.duration).max() ?? 0
    }

    /// 换文件时替换内容，但**保留 delay** —— 用户调好的延迟是他的意图，不该被一次换片抹掉。
    public mutating func replace(cues: [SubtitleCue]) {
        let sorted = Self.sorted(cues)
        self.cues = sorted
        longestDuration = sorted.map(\.duration).max() ?? 0
    }

    public mutating func setDelay(_ seconds: Double) {
        delay = Self.normalizeDelay(seconds)
    }

    public mutating func adjustDelay(by delta: Double) {
        setDelay(delay + delta)
    }

    /// 该时刻**全部**生效的字幕（按开始时间排序）。ASS 允许重叠，所以这是一个列表而不是单条。
    public func activeCues(at time: Double) -> [SubtitleCue] {
        guard !cues.isEmpty, time.isFinite else { return [] }
        let shifted = time - delay

        // 找第一个 `start > shifted` 的下标，所以答案一定落在它左边。
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= shifted {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var found: [SubtitleCue] = []
        var index = low - 1
        while index >= 0 {
            let cue = cues[index]
            // 超出"最长可能还盖着我"的距离就收工 —— 这是二分之后唯一需要回看的范围。
            if shifted - cue.start > longestDuration { break }
            if cue.contains(shifted) { found.append(cue) }
            index -= 1
        }
        return found.reversed()
    }

    /// 最上面那条（后开始者优先）。自绘渲染时"画最后一条"就是它。
    public func cue(at time: Double) -> SubtitleCue? {
        activeCues(at: time).last
    }

    /// 该时刻要显示的完整文本（多条重叠时按序拼接）。
    public func text(at time: Double) -> String? {
        let active = activeCues(at: time)
        guard !active.isEmpty else { return nil }
        return active.map(\.text).joined(separator: "\n")
    }

    private static func sorted(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.sorted { left, right in
            left.start == right.start ? left.end < right.end : left.start < right.start
        }
    }

    /// 钳到 `delayRange`，并对齐到**毫秒**。
    ///
    /// 对齐毫秒是必要的：延迟会被反复 `±0.1` 地按，浮点累加会攒出 `0.30000000000000004`，
    /// 于是"显示 0.3"与"内核收到 0.3"永远对不上，做相等断言也会莫名其妙地失败。
    public static func normalizeDelay(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let clamped = Swift.min(Swift.max(seconds, delayRange.lowerBound), delayRange.upperBound)
        return (clamped * 1000).rounded() / 1000
    }
}
