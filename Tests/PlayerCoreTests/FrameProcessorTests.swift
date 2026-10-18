import Foundation
import Testing
@testable import PlayerCore

@Suite
struct FrameProcessorTests {
    // MARK: - 夹具

    struct FakeFrame: Equatable {
        var id: Int
    }

    /// 按脚本逐个返回结果的处理器：能看到"第几次调用收到的是什么"，
    /// 这比"最后输出了什么"更能证明顺序与状态。
    final class ScriptedProcessor: FrameProcessor {
        typealias Frame = FakeFrame

        let identifier: String
        let order: Int
        var defaultOutput: FrameProcessorOutput<FakeFrame>
        private var script: [FrameProcessorOutput<FakeFrame>]

        private(set) var seenContexts: [FrameContext] = []
        private(set) var receivedFrames: [FakeFrame] = []

        init(
            _ identifier: String,
            order: Int,
            default output: FrameProcessorOutput<FakeFrame> = .unchanged,
            script: [FrameProcessorOutput<FakeFrame>] = []
        ) {
            self.identifier = identifier
            self.order = order
            self.defaultOutput = output
            self.script = script
        }

        func process(_ frame: FakeFrame, context: FrameContext) -> FrameProcessorOutput<FakeFrame> {
            receivedFrames.append(frame)
            seenContexts.append(context)
            if script.isEmpty { return defaultOutput }
            return script.removeFirst()
        }
    }

    /// 把帧号改写成固定值，方便从输出反推"是谁改的"。
    private static func marker(_ id: Int) -> FrameProcessorOutput<FakeFrame> {
        .replaced(FakeFrame(id: id))
    }

    // MARK: - 空管道 / 单处理器

    @Test
    func testEmptyPipelineReturnsTheFrameUntouched() {
        let pipeline = FramePipeline<FakeFrame>()

        let out = pipeline.submit(FakeFrame(id: 7), context: FrameContext(index: 0, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 7))
        #expect(out.applied.isEmpty)
        #expect(out.isFresh)
    }

    @Test
    func testReplacedFrameBecomesTheOutput() {
        let pipeline = FramePipeline<FakeFrame>(processors: [
            ScriptedProcessor("a", order: 0, default: Self.marker(42))
        ])

        let out = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 42))
        #expect(out.applied == [AppliedProcessor(identifier: "a", lagFrames: 0)])
    }

    @Test
    func testUnchangedLeavesTheFrameAloneAndIsNotReportedAsApplied() {
        // `.unchanged` 与 `.replaced(同一帧)` 语义不同：前者"没动手"，
        // 后者"处理过了"。若把 unchanged 也当成 applied，调用方会以为有加工发生。
        let pipeline = FramePipeline<FakeFrame>(processors: [
            ScriptedProcessor("noop", order: 0)
        ])

        let out = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 1))
        #expect(out.applied.isEmpty)
    }

    // MARK: - 顺序

    @Test
    func testExecutionFollowsOrderFieldNotArrayOrder() {
        // 数组里 c(2)、a(0)、b(1) —— 执行必须是 a、b、c。
        // 这是"顺序是语义不是实现细节"的最小判据（`docs/32` §5.4）。
        let a = ScriptedProcessor("a", order: 0, default: Self.marker(10))
        let b = ScriptedProcessor("b", order: 1, default: Self.marker(11))
        let c = ScriptedProcessor("c", order: 2, default: Self.marker(12))
        let pipeline = FramePipeline<FakeFrame>(processors: [c, a, b])

        let out = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))

        #expect(a.receivedFrames == [FakeFrame(id: 1)])
        #expect(b.receivedFrames == [FakeFrame(id: 10)])
        #expect(c.receivedFrames == [FakeFrame(id: 11)])
        #expect(out.frame == FakeFrame(id: 12))
        #expect(out.applied.map(\.identifier) == ["a", "b", "c"])
    }

    @Test
    func testEqualOrderIsResolvedByIdentifierSoRunsAreDeterministic() {
        // Swift 的 sort 不稳定 ⇒ 同 order 若不设次序，同一份输入可能今天 a→b、明天 b→a。
        let a = ScriptedProcessor("alpha", order: 5, default: Self.marker(1))
        let b = ScriptedProcessor("bravo", order: 5, default: Self.marker(2))
        let pipeline = FramePipeline<FakeFrame>(processors: [b, a])

        let out = pipeline.submit(FakeFrame(id: 0), context: FrameContext(index: 0, width: 4, height: 2))

        #expect(out.applied.map(\.identifier) == ["alpha", "bravo"])
        #expect(b.receivedFrames == [FakeFrame(id: 1)])
    }

    // MARK: - 异步未就绪

    @Test
    func testNotReadyWithPassthroughKeepsTheRawFrame() {
        let pipeline = FramePipeline<FakeFrame>(
            processors: [ScriptedProcessor("depth", order: 0, default: .notReady)],
            stalePolicy: .passthrough
        )

        let out = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 1))
        #expect(out.applied.isEmpty)
        #expect(out.isFresh)
    }

    @Test
    func testNotReadyHoldsTheLastResultAndReportsHowLateItIs() {
        // 第 0 帧处理好了；第 1、2 帧还没好 ⇒ 继续用第 0 帧的结果，并报出"迟到 1 / 2 帧"。
        let depth = ScriptedProcessor(
            "depth",
            order: 0,
            script: [Self.marker(100), .notReady, .notReady]
        )
        let pipeline = FramePipeline<FakeFrame>(
            processors: [depth],
            stalePolicy: .holdLastResult(maxAgeFrames: 5)
        )

        let first = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))
        let second = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 1, width: 4, height: 2))
        let third = pipeline.submit(FakeFrame(id: 3), context: FrameContext(index: 2, width: 4, height: 2))

        #expect(first.applied == [AppliedProcessor(identifier: "depth", lagFrames: 0)])
        #expect(second.frame == FakeFrame(id: 100))
        #expect(second.applied == [AppliedProcessor(identifier: "depth", lagFrames: 1)])
        #expect(third.applied == [AppliedProcessor(identifier: "depth", lagFrames: 2)])
    }

    @Test
    func testHoldGivesUpBeyondMaxAgeAndFallsBackToTheRawFrame() {
        // 迟到 3 帧时放弃旧结果 —— 宁可画面不加工，也不要拿一张对不上的深度图（`docs/32` §5.5）。
        let depth = ScriptedProcessor("depth", order: 0, default: .notReady, script: [Self.marker(100)])
        let pipeline = FramePipeline<FakeFrame>(
            processors: [depth],
            stalePolicy: .holdLastResult(maxAgeFrames: 2)
        )

        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))
        let out = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 3, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 2))
        #expect(out.applied.isEmpty)
    }

    @Test
    func testHoldReusesAtExactlyMaxAge() {
        // 边界必须卡死：`<=` 与 `<` 差一帧，而这一帧正是"延迟到极限"的那一帧。
        let depth = ScriptedProcessor("depth", order: 0, default: .notReady, script: [Self.marker(100)])
        let pipeline = FramePipeline<FakeFrame>(
            processors: [depth],
            stalePolicy: .holdLastResult(maxAgeFrames: 2)
        )

        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))
        let out = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 2, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 100))
        #expect(out.applied == [AppliedProcessor(identifier: "depth", lagFrames: 2)])
    }

    @Test
    func testResultFromTheFutureIsNeverReused() {
        // 时钟倒退（seek / reset 前残留）时 age 会是负数。若用 `age <= maxAge` 而不卡 `age >= 1`，
        // 一个负数就能骗过上限，拿一张"比这一帧还新"的图顶上去。
        let depth = ScriptedProcessor("depth", order: 0, default: .notReady, script: [Self.marker(100)])
        let pipeline = FramePipeline<FakeFrame>(
            processors: [depth],
            stalePolicy: .holdLastResult(maxAgeFrames: 5)
        )

        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 9, width: 4, height: 2))
        let out = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 1, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 2))
        #expect(out.applied.isEmpty)
    }

    @Test
    func testMaxAgeZeroNeverReusesAnOlderResult() {
        // 边界：maxAge = 0 等于"永不复用"，退化到 passthrough。
        let depth = ScriptedProcessor("depth", order: 0, default: .notReady, script: [Self.marker(100)])
        let pipeline = FramePipeline<FakeFrame>(
            processors: [depth],
            stalePolicy: .holdLastResult(maxAgeFrames: 0)
        )

        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))
        let out = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 1, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 2))
        #expect(out.applied.isEmpty)
    }

    @Test
    func testReplacementRefreshesWhatWillBeHeldLater() {
        // 处理器恢复到"就绪"之后，下一次 notReady 拿到的是**新的**那一帧，而不是最初的。
        let depth = ScriptedProcessor(
            "depth",
            order: 0,
            script: [Self.marker(100), Self.marker(200), .notReady]
        )
        let pipeline = FramePipeline<FakeFrame>(
            processors: [depth],
            stalePolicy: .holdLastResult(maxAgeFrames: 5)
        )

        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))
        _ = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 1, width: 4, height: 2))
        let out = pipeline.submit(FakeFrame(id: 3), context: FrameContext(index: 2, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 200))
        #expect(out.applied == [AppliedProcessor(identifier: "depth", lagFrames: 1)])
    }

    @Test
    func testHoldIsPerProcessorNotGlobal() {
        // a 迟到、b 按时 —— b 不能被 a 的迟到拖住。
        let a = ScriptedProcessor("a", order: 0, default: .notReady, script: [Self.marker(10)])
        let b = ScriptedProcessor("b", order: 1, script: [Self.marker(20), Self.marker(21)])
        let pipeline = FramePipeline<FakeFrame>(
            processors: [a, b],
            stalePolicy: .holdLastResult(maxAgeFrames: 5)
        )

        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))
        let out = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 1, width: 4, height: 2))

        #expect(out.applied == [
            AppliedProcessor(identifier: "a", lagFrames: 1),
            AppliedProcessor(identifier: "b", lagFrames: 0)
        ])
        #expect(out.maxLagFrames == 1)
        // b 收到的是 a 的结果（第 0 帧是新算的 10，第 1 帧是顶替的 10）——
        // **b 从没见过原帧 1**，这就是"顺序在前 ⇒ 下游继承上游的旧结果"。
        #expect(b.receivedFrames == [FakeFrame(id: 10), FakeFrame(id: 10)])
    }

    // MARK: - 上下文与复位

    @Test
    func testContextIsForwardedVerbatim() {
        // 处理器要按 time-pos 对齐（字幕已经这么做），所以上下文不能在中途被改写。
        let probe = ScriptedProcessor("probe", order: 0)
        let pipeline = FramePipeline<FakeFrame>(processors: [probe])
        let context = FrameContext(index: 9, presentationTime: 12.5, width: 1920, height: 800)

        _ = pipeline.submit(FakeFrame(id: 1), context: context)

        #expect(probe.seenContexts == [context])
    }

    @Test
    func testResetDropsHeldResults() {
        let depth = ScriptedProcessor("depth", order: 0, default: .notReady, script: [Self.marker(100)])
        let pipeline = FramePipeline<FakeFrame>(
            processors: [depth],
            stalePolicy: .holdLastResult(maxAgeFrames: 5)
        )

        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))
        pipeline.reset()
        let out = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 1, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 2))
        #expect(out.applied.isEmpty)
    }

    @Test
    func testReplacingTheProcessorListAlsoDropsHeldResults() {
        // 换处理器 = 换语义，旧的中间结果没有意义。
        let first = ScriptedProcessor("depth", order: 0, script: [Self.marker(100)])
        let pipeline = FramePipeline<FakeFrame>(
            processors: [first],
            stalePolicy: .holdLastResult(maxAgeFrames: 5)
        )
        _ = pipeline.submit(FakeFrame(id: 1), context: FrameContext(index: 0, width: 4, height: 2))

        let second = ScriptedProcessor("depth", order: 0, script: [.notReady, .notReady])
        pipeline.setProcessors([second])
        let out = pipeline.submit(FakeFrame(id: 2), context: FrameContext(index: 1, width: 4, height: 2))

        #expect(out.frame == FakeFrame(id: 2))
        #expect(out.applied.isEmpty)
    }
}
