import Foundation
import Testing
@testable import PlayerCore

/// `ColorLUT` 的 CPU 侧语义。**这些断言就是 GPU 侧要遵守的同一份定义** ——
/// `LUTFrameProcessorTests` 拿 GPU 读回来的像素跟这里比，比的是同一套插值口径。
@Suite
struct ColorLUTTests {
    // MARK: - 夹具

    /// 2×2×2 反相：`value = 1 - rgb`。红变最快（`.cube` 的顺序）。
    static let invertCube = """
    # 反相 LUT
    TITLE "invert"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0.0 0.0 0.0
    DOMAIN_MAX 1.0 1.0 1.0
    1 1 1
    0 1 1
    1 0 1
    0 0 1
    1 1 0
    0 1 0
    1 0 0
    0 0 0
    """

    static func invert() throws -> ColorLUT {
        try ColorLUT.parse(invertCube)
    }

    // MARK: - 解析

    @Test
    func testParsesSizeAndValues() throws {
        let lut = try Self.invert()

        #expect(lut.dimension == 2)
        #expect(lut.values.count == 2 * 2 * 2 * 3)
        #expect(lut.domainMin == SIMD3<Float>(0, 0, 0))
        #expect(lut.domainMax == SIMD3<Float>(1, 1, 1))
    }

    /// **红最快**是 `.cube` 的定义，不是实现自由。顺序错了，LUT 会把颜色通道错位，
    /// 而画面看起来"只是偏色" —— 那种错最难从像素上看出来，只能靠这条断言钉住。
    @Test
    func testRedVariesFastest() throws {
        let lut = try Self.invert()

        // 第 0 个是 (r=0,g=0,b=0) ⇒ 反相后 (1,1,1)
        #expect(lut.values[0 ... 2] == [1, 1, 1])
        // 第 1 个是 (r=1,g=0,b=0) ⇒ (0,1,1)
        #expect(lut.values[3 ... 5] == [0, 1, 1])
        // 第 2 个是 (r=0,g=1,b=0) ⇒ (1,0,1)
        #expect(lut.values[6 ... 8] == [1, 0, 1])
        // 第 4 个是 (r=0,g=0,b=1) ⇒ (1,1,0)
        #expect(lut.values[12 ... 14] == [1, 1, 0])
    }

    @Test
    func testRejectsMissingSize() {
        #expect(throws: ColorLUT.ParseError.missingSize) {
            try ColorLUT.parse("0 0 0\n1 1 1")
        }
    }

    /// 1D LUT 是**另一件事**（逐通道曲线），悄悄当成 3D 用会让整段画面的颜色错位。
    /// 明确拒绝，错误信息里说清"不支持"，比猜用户想要什么好。
    @Test
    func testRejectsOneDimensionalLUT() {
        #expect(throws: ColorLUT.ParseError.oneDimensionalUnsupported) {
            try ColorLUT.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1")
        }
    }

    @Test
    func testRejectsWrongValueCount() {
        #expect(throws: ColorLUT.ParseError.valueCount(actual: 9, expected: 24)) {
            try ColorLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n0.5 0.5 0.5")
        }
    }

    @Test
    func testRejectsMalformedValueLine() {
        #expect(throws: ColorLUT.ParseError.malformedValue(triple: 1, text: "0 0")) {
            try ColorLUT.parse("LUT_3D_SIZE 2\n0 0 0\n0 0")
        }
    }

    @Test
    func testRejectsOneDimensionalSizeOfOne() {
        // size=1 时插值分母为 0（`dimension - 1`），是一张没有意义的 LUT。
        #expect(throws: ColorLUT.ParseError.dimensionOutOfRange(1)) {
            try ColorLUT.parse("LUT_3D_SIZE 1\n0 0 0")
        }
    }

    @Test
    func testIgnoresBlankLinesAndCRLF() throws {
        let text = "LUT_3D_SIZE 2\r\n\r\n0 0 0\r\n0 0 1\r\n0 1 0\r\n0 1 1\r\n1 0 0\r\n1 0 1\r\n1 1 0\r\n1 1 1\r\n"
        let lut = try ColorLUT.parse(text)

        #expect(lut.dimension == 2)
        #expect(lut.values.count == 24)
        // 最后一个是 (1,1,1) ⇒ 按红最快，索引 7
        #expect(lut.values[21 ... 23] == [1, 1, 1])
    }

    /// **公开 `init` 自己的守卫也要有测试**。
    ///
    /// 变异验证暴露过这条：`dimension >= 2` 写在两处（`parse` 一处、`init` 一处），
    /// 只有 `parse` 那条路被覆盖，于是把 `init` 里的守卫改成 `>= 1` 时**没有任何测试变红**
    /// （`P-098`）。两处同义检查 ⇒ 两处都要有入口。
    @Test
    func testPublicInitRejectsUnusableTables() {
        // 尺寸 1：插值分母为 0
        #expect(ColorLUT(dimension: 1, values: [0, 0, 0]) == nil)
        // 份数对不上
        #expect(ColorLUT(dimension: 2, values: [0, 0, 0]) == nil)
        // domain 反向（这一维 max 不大于 min）
        let flat = [Float](repeating: 0, count: 24)
        #expect(
            ColorLUT(
                dimension: 2, values: flat,
                domainMin: SIMD3<Float>(0, 0, 0), domainMax: SIMD3<Float>(1, 0, 1)
            ) == nil
        )
    }

    @Test
    func testDomainIsApplied() throws {
        let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 2 2 2
        0 0 0
        0 0 1
        0 1 0
        0 1 1
        1 0 0
        1 0 1
        1 1 0
        1 1 1
        """
        let lut = try ColorLUT.parse(text)

        #expect(lut.domainMax == SIMD3<Float>(2, 2, 2))
        // 输入 1.0 在 [0,2] 里位于正中 ⇒ 插值出 0.5
        let mid = lut.sample(SIMD3<Float>(1, 1, 1))
        #expect(abs(mid.x - 0.5) < 1e-6)
        // 输入 2.0 是域上界 ⇒ 命中最末节点
        let top = lut.sample(SIMD3<Float>(2, 2, 2))
        #expect(abs(top.x - 1) < 1e-6)
    }

    // MARK: - CPU 采样（GPU 侧的对账基准）

    @Test
    func testIdentityLUTIsExact() {
        let lut = ColorLUT.identity
        let color = SIMD3<Float>(0.37, 0.5, 0.9)

        let out = lut.sample(color)

        // 线性函数的三线性插值是**精确**的（不是"近似"）—— 所以这里不留容差。
        #expect(out == color)
    }

    @Test
    func testInvertIsExactAtNodes() throws {
        let lut = try Self.invert()

        #expect(lut.sample(SIMD3<Float>(0, 0, 0)) == SIMD3<Float>(1, 1, 1))
        #expect(lut.sample(SIMD3<Float>(1, 1, 1)) == SIMD3<Float>(0, 0, 0))
        #expect(lut.sample(SIMD3<Float>(1, 0, 0)) == SIMD3<Float>(0, 1, 1))
    }

    /// 节点正中（0.5）必须等于 8 个角的平均 —— 这条是**插值有没有真的发生**的判据。
    /// 若实现退化成"取最近的节点"，这里会得到 0 或 1 而不是 0.5。
    @Test
    func testMidpointIsTheAverageOfCorners() throws {
        let lut = try Self.invert()

        let mid = lut.sample(SIMD3<Float>(0.5, 0.5, 0.5))

        #expect(abs(mid.x - 0.5) < 1e-6)
        #expect(abs(mid.y - 0.5) < 1e-6)
        #expect(abs(mid.z - 0.5) < 1e-6)
    }

    /// 只让红轴有梯度：`value = (r, g, b)` 但 r 换成 `1 - r`。用来验证**轴没有串**。
    @Test
    func testOnlyTheRequestedAxisMoves() throws {
        let text = """
        LUT_3D_SIZE 2
        1 0 0
        0 0 0
        1 1 0
        0 1 0
        1 0 1
        0 0 1
        1 1 1
        0 1 1
        """
        let lut = try ColorLUT.parse(text)

        let out = lut.sample(SIMD3<Float>(1, 0, 0))

        #expect(out == SIMD3<Float>(0, 0, 0))
        // g=b=0、r=1 时只有红被翻转，另两个通道必须原样回来
        #expect(lut.sample(SIMD3<Float>(1, 0.25, 0.75)).y == 0.25)
        #expect(lut.sample(SIMD3<Float>(1, 0.25, 0.75)).z == 0.75)
    }

    /// 超出 [0,1] 的输入必须**夹住**，不是取模、也不是崩溃。
    /// HDR 素材与 YUV→RGB 的溢出都会给出这种值。
    @Test
    func testSampleClampsOutOfRangeInput() throws {
        let lut = try Self.invert()

        #expect(lut.sample(SIMD3<Float>(-3, 5, 0.5)).x == 1) // 反转后 (-3) 夹到 0 ⇒ 1
        #expect(lut.sample(SIMD3<Float>(-3, 5, 0.5)).y == 0)
    }

    @Test
    func testIdentityHasNoEffectOnAnyChannel() {
        for r in stride(from: Float(0), through: 1, by: 0.125) {
            let out = ColorLUT.identity.sample(SIMD3<Float>(r, 1 - r, 0.5))
            #expect(out == SIMD3<Float>(r, 1 - r, 0.5))
        }
    }

    /// 库自带的反相表：两端必须落在 (1,1,1) 与 (0,0,0)，中间必须是 0.5。
    /// 这三条一起才说明"梯度是按节点均匀铺开的"，而不是某个角被写死了。
    @Test
    func testInvertedFactorySpansBothEnds() throws {
        let lut = try #require(ColorLUT.inverted(dimension: 5))

        #expect(lut.dimension == 5)
        #expect(lut.node(0, 0, 0) == SIMD3<Float>(1, 1, 1))
        #expect(lut.node(4, 4, 4) == SIMD3<Float>(0, 0, 0))
        #expect(abs(lut.sample(SIMD3<Float>(0.5, 0.5, 0.5)).x - 0.5) < 1e-6)
        // 与 `parse` 那条路一样，尺寸 1 不给
        #expect(ColorLUT.inverted(dimension: 1) == nil)
    }
}
