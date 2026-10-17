import Testing
@testable import PlayerCore

@Suite
struct FrameTimingStatsTests {
    @Test
    func testEmptyRecorderProducesZeroStats() {
        let stats = FrameTimingRecorder().stats()

        #expect(stats.count == 0)
        #expect(stats.p50 == 0)
        #expect(stats.p95 == 0)
        #expect(stats.max == 0)
        #expect(stats.sustainableFPS == 0, "没有样本时不能除以 0 得到无穷大")
    }

    @Test
    func testPercentilesUseNearestRank() {
        // 1…100 ms：p50 应取**第 50 个真实样本**（= 50），不是插值出来的 50.5。
        var recorder = FrameTimingRecorder()
        for value in 1 ... 100 {
            recorder.record(milliseconds: Double(value))
        }

        let stats = recorder.stats()
        #expect(stats.count == 100)
        #expect(stats.p50 == 50)
        #expect(stats.p95 == 95)
        #expect(stats.max == 100)
        #expect(abs(stats.mean - 50.5) < 1e-9)
    }

    @Test
    func testSustainableFPSIsDerivedFromP95() {
        // 20 帧里 2 帧是 40 ms 的尖刺：平均 11.2 ms（看着像 89 fps），p95 是 40 ms（25 fps）。
        // 这就是"用 p95 而不是平均值"的整个理由。
        //
        // ⚠️ 为什么是 **2 帧**而不是 1 帧：最近秩法下 p95 取第 ⌈0.95×20⌉ = 19 个样本，
        // 只有 1 个尖刺时它排在第 20 位 —— p95 仍然落在 8 ms 上。
        // （第一版用例写了 1 帧，红的就是它自己：**断言比实现更乐观**。）
        var recorder = FrameTimingRecorder()
        for index in 0 ..< 20 {
            recorder.record(milliseconds: index >= 18 ? 40 : 8)
        }

        let stats = recorder.stats()
        #expect(stats.mean < 12)
        #expect(stats.p95 == 40)
        #expect(stats.sustainableFPS == 25)
    }

    @Test
    func testSingleSampleIsItsOwnPercentile() {
        var recorder = FrameTimingRecorder()
        recorder.record(milliseconds: 12.5)

        let stats = recorder.stats()
        #expect(stats.count == 1)
        #expect(stats.p50 == 12.5)
        #expect(stats.p95 == 12.5)
        #expect(stats.max == 12.5)
    }

    @Test
    func testRecorderStopsAtLimit() {
        var recorder = FrameTimingRecorder(limit: 3)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0] {
            recorder.record(milliseconds: value)
        }

        let stats = recorder.stats()
        #expect(stats.count == 3)
        #expect(stats.max == 3, "超出上限的样本被丢弃，最大值也只能来自保留下来的那几个")
    }

    @Test
    func testNegativeAndNonFiniteSamplesAreIgnored() {
        var recorder = FrameTimingRecorder()
        recorder.record(milliseconds: -1)
        recorder.record(milliseconds: .nan)
        recorder.record(milliseconds: .infinity)
        recorder.record(milliseconds: 5)

        let stats = recorder.stats()
        #expect(stats.count == 1)
        #expect(stats.max == 5)
    }

    @Test
    func testSummaryCarriesTheNumbersItClaimsTo() {
        var recorder = FrameTimingRecorder()
        recorder.record(milliseconds: 10)
        recorder.record(milliseconds: 20)

        let summary = recorder.stats().summary
        #expect(summary.contains("n=2"))
        #expect(summary.contains("p50=10.00ms"))
        #expect(summary.contains("p95=20.00ms"))
    }
}
