import Foundation

/// 一帧的**上下文**：处理器据此对齐时间，据说不是装饰。
///
/// `presentationTime` 用 mpv 的 `time-pos`（显示时刻），不是墙钟 —— 字幕已经这么做
/// （`SubtitleOverlaySource`）。理由相同：墙钟会被缓冲与卡顿带偏，对表就错。
public struct FrameContext: Sendable, Equatable {
    /// 我们自己数的第几帧（从 0 起）。**不是** mpv 的帧号 —— 跳转后会重排。
    public let index: Int
    /// 显示时刻（秒）。`nil` = 这一刻拿不到（例如刚 `loadfile`、或直播流未就绪）。
    public let presentationTime: Double?
    /// 这一帧的像素尺寸（mpv 实际渲染到的尺寸，不是源尺寸）。
    public let width: Int
    public let height: Int

    public init(index: Int, presentationTime: Double? = nil, width: Int, height: Int) {
        self.index = index
        self.presentationTime = presentationTime
        self.width = width
        self.height = height
    }
}

/// 一个处理器对一帧的答复，只有三种。
///
/// 故意**不提供"丢弃这一帧"**：丢帧的表现是卡顿，而"拿旧结果顶一下"的表现是延迟。
/// 前者肉眼可见且无从解释，后者可以靠 `lagFrames` 报出来。既然这条路线要的是
/// "一个处理器慢了不能让播放卡住"，就不该让最粗暴的那个选项存在（`docs/32` §5.2）。
public enum FrameProcessorOutput<Frame> {
    /// 没动手（不适用 / 已关闭）。**不等于**"处理了但结果一样"。
    case unchanged
    /// 处理完成，用这一帧替换。
    case replaced(Frame)
    /// 异步还没好。用哪一个由 `StaleFramePolicy` 决定，不由处理器自己决定。
    case notReady
}

/// 帧处理器：**改写帧**的那一层。
///
/// 与"叠加层"（`SubtitleOverlaySource`，画在画面之上、不改帧）是**两个概念**，别混：
/// 叠加层可以每帧重画且不影响下游；处理器会改变下游看到的内容，所以顺序是语义。
public protocol FrameProcessor<Frame> {
    associatedtype Frame

    /// 稳定标识。用于两处：同 `order` 时的**确定性次序**，以及"上一次结果"的归属。
    /// 换语义就要换名字 —— 否则旧的中间结果会被误认成新处理器的结果。
    var identifier: String { get }

    /// 越小越先执行。同 `order` 按 `identifier` 字典序排 —— Swift 的排序不稳定，
    /// 不设这个次序，同一份输入可能今天 a→b、明天 b→a。
    var order: Int { get }

    func process(_ frame: Frame, context: FrameContext) -> FrameProcessorOutput<Frame>
}

/// 处理器"还没好"时怎么办。
public enum StaleFramePolicy: Sendable, Equatable {
    /// 原帧直接过。最保守，画面不加工但不延迟。
    case passthrough
    /// 用这个处理器**上一次**的结果顶替；超过 `maxAgeFrames` 帧就退回 `passthrough`。
    ///
    /// 为什么要有上限：迟到太久的结果对应的是"另一幅画面"，叠上去会**对不上**
    /// （2D→3D 场景下表现为晕）。宁可这一帧不加工。
    case holdLastResult(maxAgeFrames: Int)
}

/// 一个实际生效的处理器，以及它的结果**迟到了几帧**（0 = 就是这一帧的）。
public struct AppliedProcessor: Sendable, Equatable {
    public let identifier: String
    public let lagFrames: Int

    public init(identifier: String, lagFrames: Int) {
        self.identifier = identifier
        self.lagFrames = lagFrames
    }
}

/// 管道跑完一帧的结果。
public struct FramePipelineOutput<Frame> {
    /// 交给下游上屏的那一帧（可能是原帧、某个处理器的结果、或上一次的旧结果）。
    public let frame: Frame
    /// 按执行顺序列出真正动了手的处理器。空 = 这一帧等于没加工。
    public let applied: [AppliedProcessor]

    public init(frame: Frame, applied: [AppliedProcessor]) {
        self.frame = frame
        self.applied = applied
    }

    /// 最大的迟到帧数。大于 0 说明这一帧的画面对不上那一帧的时间。
    public var maxLagFrames: Int {
        applied.map(\.lagFrames).max() ?? 0
    }

    public var isFresh: Bool {
        maxLagFrames == 0
    }
}

/// 处理器链 + 迟到策略。
///
/// 这一层**不碰 Metal / 像素**，所以它可以在 mac 上纯逻辑单测（`FrameProcessorTests`）；
/// `Frame` 在适配器里实例化成 `MTLTexture`。纯逻辑是刻意的：调度出错的表现是"随机卡顿，
/// 分不清谁在等谁"，那种问题只能靠可重放的测试抓（`docs/32` §5.2）。
public final class FramePipeline<Frame> {
    private var sorted: [any FrameProcessor<Frame>]
    /// 每个处理器上一次**成功产出**的结果，用于 `holdLastResult`。
    private var lastResults: [String: (frame: Frame, index: Int)] = [:]

    public var stalePolicy: StaleFramePolicy

    /// 当前处理器，**按执行顺序**排列（不是调用方传进来的顺序）。
    public var processors: [any FrameProcessor<Frame>] { sorted }

    public init(
        processors: [any FrameProcessor<Frame>] = [],
        stalePolicy: StaleFramePolicy = .holdLastResult(maxAgeFrames: 2)
    ) {
        self.stalePolicy = stalePolicy
        self.sorted = Self.order(processors)
    }

    /// 换处理器。**同时清掉旧结果** —— 换了语义，旧中间结果没有归属了。
    public func setProcessors(_ processors: [any FrameProcessor<Frame>]) {
        sorted = Self.order(processors)
        reset()
    }

    /// 清掉所有"上一次结果"（seek / 换片 / 换尺寸时调用）。
    public func reset() {
        lastResults.removeAll()
    }

    public func submit(_ frame: Frame, context: FrameContext) -> FramePipelineOutput<Frame> {
        var current = frame
        var applied: [AppliedProcessor] = []

        for processor in sorted {
            switch processor.process(current, context: context) {
            case .unchanged:
                continue

            case .replaced(let newFrame):
                current = newFrame
                lastResults[processor.identifier] = (newFrame, context.index)
                applied.append(AppliedProcessor(identifier: processor.identifier, lagFrames: 0))

            case .notReady:
                switch stalePolicy {
                case .passthrough:
                    continue

                case .holdLastResult(let maxAge):
                    guard let last = lastResults[processor.identifier] else { continue }
                    let age = context.index - last.index
                    // `age < 0` 说明时钟倒退了（seek 之后 index 是单调的，但 reset 前的残留
                    // 可能落在未来）—— 一律当成不可用，不要用"负数迟到"骗过上限判断。
                    guard age >= 1, age <= maxAge else { continue }
                    current = last.frame
                    applied.append(AppliedProcessor(identifier: processor.identifier, lagFrames: age))
                }
            }
        }

        return FramePipelineOutput(frame: current, applied: applied)
    }

    private static func order(_ processors: [any FrameProcessor<Frame>]) -> [any FrameProcessor<Frame>] {
        processors.sorted {
            $0.order != $1.order ? $0.order < $1.order : $0.identifier < $1.identifier
        }
    }
}
