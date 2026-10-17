import Foundation

/// 一段渲染耗时的**分布**（毫秒）。
///
/// 为什么不是"平均值"：`docs/24` 要回答的是"软件后端能不能当渲染管线"，那就得看
/// **抖动**。平均值 8 ms 但 p95 = 40 ms 的后端，平均看"125 fps 够用"，
/// 实际上每 20 帧就掉一次 —— 平均值把这类问题完整地藏起来。
public struct FrameTimingStats: Sendable, Equatable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let max: Double
    public let mean: Double

    public init(count: Int, p50: Double, p95: Double, max: Double, mean: Double) {
        self.count = count
        self.p50 = p50
        self.p95 = p95
        self.max = max
        self.mean = mean
    }

    /// 按 p95 折算的帧率上限 —— **用 p95 而不是 p50**：给"最差的那些帧"留预算，
    /// 否则算出来的帧率是"偶尔能达到"的帧率。
    public var sustainableFPS: Double {
        p95 > 0 ? 1000 / p95 : 0
    }

    /// 一行可读摘要（日志/文档直接抄，不做二次加工）。
    public var summary: String {
        String(
            format: "n=%d p50=%.2fms p95=%.2fms max=%.2fms mean=%.2fms ⇒ p95 折算 %.1f fps",
            count, p50, p95, max, mean, sustainableFPS
        )
    }
}

/// 逐帧计时的收集器。
///
/// 采样**只保留到上限**（默认 5000 条）：一次 4K 长跑的能量足以把这个数组堆到几十 MB，
/// 而 p50/p95 在几千条之后已经稳定 —— 拿内存换精度是不划算的。
public struct FrameTimingRecorder: Sendable {
    private var samples: [Double] = []
    private let limit: Int

    public init(limit: Int = 5000) {
        self.limit = max(1, limit)
    }

    public mutating func record(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        guard samples.count < limit else { return }
        samples.append(milliseconds)
    }

    public var isEmpty: Bool { samples.isEmpty }

    public func stats() -> FrameTimingStats {
        guard !samples.isEmpty else {
            return FrameTimingStats(count: 0, p50: 0, p95: 0, max: 0, mean: 0)
        }
        let sorted = samples.sorted()
        let total = sorted.reduce(0, +)
        return FrameTimingStats(
            count: sorted.count,
            p50: Self.percentile(sorted, 0.50),
            p95: Self.percentile(sorted, 0.95),
            max: sorted[sorted.count - 1],
            mean: total / Double(sorted.count)
        )
    }

    /// 最近秩（nearest-rank）法：取**第 ⌈p·n⌉ 个**样本。
    ///
    /// 不用插值：样本是"真实发生过的帧"，插出来的数**没有对应的那一帧**，
    /// 拿它去和"每一帧都有预算"的帧率上限对照会偏乐观。
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
