import Foundation
import Metal
import Testing
@testable import PlayerCore
@testable import PlayerProcessors

/// **GPU 侧的第一份取证**：真的跑一趟 Metal pass，把像素读回来，跟 `ColorLUT.sample` 对账。
///
/// 本机（Apple Silicon）`swift test` 里 `MTLCreateSystemDefaultDevice()` 可用，
/// 所以这一层不需要真机、不需要截图、不需要人眼 —— 判据是**数字**。
@Suite
struct LUTFrameProcessorTests {
    // MARK: - 夹具

    /// 一台设备 + 一条队列。**队列与"上屏"共用**是产品上的要求（见 `MetalPassProcessor`），
    /// 在测试里共用是为了让"提交即有序"这条前提与产品一致。
    struct Fixture {
        let device: MTLDevice
        let queue: MTLCommandQueue

        init() throws {
            device = try #require(MTLCreateSystemDefaultDevice(), "没有 Metal 设备：本机跑不了这组测试")
            queue = try #require(device.makeCommandQueue())
        }

        /// 造一张 CPU 可写、GPU 可读的 bgra8 输入纹理。入参按 **RGB** 给，内部排成 BGRA。
        func makeSource(width: Int, height: Int, pixels: [(r: UInt8, g: UInt8, b: UInt8)]) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            var bytes = [UInt8]()
            bytes.reserveCapacity(width * height * 4)
            for pixel in pixels {
                bytes.append(contentsOf: [pixel.b, pixel.g, pixel.r, 255])
            }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4
            )
            return texture
        }

        /// 把一张纹理拷进可读纹理后取回 BGRA 字节。**拷完等完成** —— 不等就会读到全零，
        /// 而"全零"恰好长得像"处理器把画面变黑"，是最容易误判的形状。
        func readBack(_ texture: MTLTexture) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            let target = try #require(device.makeTexture(descriptor: descriptor))
            let buffer = try #require(queue.makeCommandBuffer())
            let blit = try #require(buffer.makeBlitCommandEncoder())
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: target, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()

            let bytesPerRow = texture.width * 4
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
            target.getBytes(
                &bytes, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
            )
            return stride(from: 0, to: bytes.count, by: 4).map {
                (r: bytes[$0 + 2], g: bytes[$0 + 1], b: bytes[$0])
            }
        }

        /// 跑一帧并等它真的落地，返回读回的像素。
        func run(
            _ processor: some FrameProcessor<MTLTexture>, on source: MTLTexture, index: Int = 0
        ) throws -> (pixels: [(r: UInt8, g: UInt8, b: UInt8)], output: MTLTexture) {
            let result = processor.process(
                source, context: FrameContext(index: index, width: source.width, height: source.height)
            )
            guard case .replaced(let output) = result else {
                Issue.record("处理器返回了 \(result)，期望 .replaced")
                throw CancellationError()
            }
            return (try readBack(output), output)
        }
    }

    /// 2×2×2 反相（`value = 1 - rgb`）—— 与 `ColorLUTTests` 用的是同一张，
    /// 两份实现（CPU / GPU）比的是同一份输入。
    static func invertLUT() throws -> ColorLUT {
        try ColorLUT.parse("""
        LUT_3D_SIZE 2
        1 1 1
        0 1 1
        1 0 1
        0 0 1
        1 1 0
        0 1 0
        1 0 0
        0 0 0
        """)
    }

    static func samples() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        [
            (0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0),
            (0, 0, 255), (128, 128, 128), (17, 200, 64), (250, 3, 190)
        ]
    }

    // MARK: - 三件事：不改变 / 改变 / 按插值改变

    /// 恒等 LUT 必须**逐像素不变**。这是"pass 真的在跑、且没有把画面搞坏"的底线。
    @Test
    func testIdentityLUTLeavesPixelsUntouched() throws {
        let fixture = try Fixture()
        let source = try fixture.makeSource(width: 4, height: 2, pixels: Self.samples())
        let processor = try LUTFrameProcessor(lut: .identity, device: fixture.device, queue: fixture.queue)

        let result = try fixture.run(processor, on: source)

        for (index, pixel) in result.pixels.enumerated() {
            let expected = Self.samples()[index]
            #expect(abs(Int(pixel.r) - Int(expected.r)) <= 1, "第 \(index) 个像素的红通道变了")
            #expect(abs(Int(pixel.g) - Int(expected.g)) <= 1)
            #expect(abs(Int(pixel.b) - Int(expected.b)) <= 1)
        }
    }

    /// 反相 LUT：输出必须是 `255 - 输入`。**方向反了也是 255-v** 的一半场合看不出来，
    /// 所以下面还专门查了红/绿/蓝三个单通道。
    @Test
    func testInvertLUTInvertsPixels() throws {
        let fixture = try Fixture()
        let source = try fixture.makeSource(width: 4, height: 2, pixels: Self.samples())
        let processor = try LUTFrameProcessor(lut: try Self.invertLUT(), device: fixture.device, queue: fixture.queue)

        let result = try fixture.run(processor, on: source)

        for (index, pixel) in result.pixels.enumerated() {
            let input = Self.samples()[index]
            #expect(abs(Int(pixel.r) - (255 - Int(input.r))) <= 2, "第 \(index) 个像素红通道反相不准")
            #expect(abs(Int(pixel.g) - (255 - Int(input.g))) <= 2)
            #expect(abs(Int(pixel.b) - (255 - Int(input.b))) <= 2)
        }
    }

    /// **插值有没有真的发生**：中灰（0.5）落在 8 个节点的正中，反相后应当仍是中灰。
    /// 若坐标换算漏了 `+0.5`（texel 中心对齐），这里会偏向某一侧节点 ⇒ 明显偏离 127.5。
    @Test
    func testMidGrayStaysMidGrayUnderInterpolation() throws {
        let fixture = try Fixture()
        let source = try fixture.makeSource(width: 1, height: 1, pixels: [(128, 128, 128)])
        let processor = try LUTFrameProcessor(lut: try Self.invertLUT(), device: fixture.device, queue: fixture.queue)

        let result = try fixture.run(processor, on: source)

        let pixel = try #require(result.pixels.first)
        #expect(abs(Int(pixel.r) - 127) <= 2, "中灰经过反相后偏了：\(pixel.r)")
        #expect(abs(Int(pixel.g) - 127) <= 2)
        #expect(abs(Int(pixel.b) - 127) <= 2)
    }

    /// `strength` 是**混合比例**：0 等于关掉（原画），1 等于全量。
    @Test
    func testStrengthZeroLeavesTheFrameAlone() throws {
        let fixture = try Fixture()
        let source = try fixture.makeSource(width: 2, height: 1, pixels: [(200, 100, 50), (0, 0, 0)])
        let processor = try LUTFrameProcessor(
            lut: try Self.invertLUT(), device: fixture.device, queue: fixture.queue, strength: 0
        )

        let result = try fixture.run(processor, on: source)

        #expect(abs(Int(result.pixels[0].r) - 200) <= 1)
        #expect(abs(Int(result.pixels[0].g) - 100) <= 1)
        #expect(abs(Int(result.pixels[0].b) - 50) <= 1)
    }

    @Test
    func testStrengthHalfBlendsTowardsTheLUTResult() throws {
        let fixture = try Fixture()
        let source = try fixture.makeSource(width: 1, height: 1, pixels: [(200, 0, 100)])
        let processor = try LUTFrameProcessor(
            lut: try Self.invertLUT(), device: fixture.device, queue: fixture.queue, strength: 0.5
        )

        let result = try fixture.run(processor, on: source)

        // mix(200, 55, 0.5) = 127.5；mix(0, 255, 0.5) = 127.5；mix(100, 155, 0.5) = 127.5
        let pixel = try #require(result.pixels.first)
        #expect(abs(Int(pixel.r) - 128) <= 2, "strength 混合比例不对：\(pixel.r)")
        #expect(abs(Int(pixel.g) - 128) <= 2)
        #expect(abs(Int(pixel.b) - 128) <= 2)
    }

    // MARK: - 与 CPU 实现逐点对账

    /// **GPU 与 CPU 必须是同一份定义**。这条测试的意义不是"再验一次反相"，
    /// 而是把两张实现钉在一起：以后改插值口径，两边必须一起改。
    @Test
    func testGPUMatchesTheCPUReferenceOnEverySample() throws {
        let fixture = try Fixture()
        let lut = try ColorLUT.parse("""
        LUT_3D_SIZE 2
        0.9 0.1 0.2
        0.1 0.8 0.3
        0.2 0.3 0.7
        0.5 0.5 0.5
        1.0 0.0 0.0
        0.0 1.0 0.0
        0.0 0.0 1.0
        0.33 0.66 0.99
        """)
        let source = try fixture.makeSource(width: 4, height: 2, pixels: Self.samples())
        let processor = try LUTFrameProcessor(lut: lut, device: fixture.device, queue: fixture.queue)

        let result = try fixture.run(processor, on: source)

        for (index, input) in Self.samples().enumerated() {
            let reference = lut.sample(
                SIMD3<Float>(Float(input.r) / 255, Float(input.g) / 255, Float(input.b) / 255)
            )
            let pixel = result.pixels[index]
            // 容差 2/255：硬件三线性用 half 精度插值，允许最后一格的差。
            #expect(abs(Int(pixel.r) - Int(reference.x * 255 + 0.5)) <= 2, "像素 \(index) 红：GPU \(pixel.r) vs CPU \(reference.x * 255)")
            #expect(abs(Int(pixel.g) - Int(reference.y * 255 + 0.5)) <= 2, "像素 \(index) 绿：GPU \(pixel.g) vs CPU \(reference.y * 255)")
            #expect(abs(Int(pixel.b) - Int(reference.z * 255 + 0.5)) <= 2, "像素 \(index) 蓝：GPU \(pixel.b) vs CPU \(reference.z * 255)")
        }
    }

    // MARK: - 输出纹理

    /// 输出尺寸跟着输入走，换尺寸后池要重建 —— 不重建就会拿旧尺寸的纹理去当 render target
    /// （Metal 会直接报错或写出界，而日志里只有一句 pipeline 报错）。
    @Test
    func testOutputSizeFollowsTheInputAcrossResizes() throws {
        let fixture = try Fixture()
        let processor = try LUTFrameProcessor(lut: .identity, device: fixture.device, queue: fixture.queue)
        let small = try fixture.makeSource(width: 2, height: 2, pixels: Array(repeating: (10, 20, 30), count: 4))
        let wide = try fixture.makeSource(width: 6, height: 1, pixels: Array(repeating: (10, 20, 30), count: 6))

        let first = try fixture.run(processor, on: small, index: 0)
        let second = try fixture.run(processor, on: wide, index: 1)

        #expect(first.output.width == 2 && first.output.height == 2)
        #expect(second.output.width == 6 && second.output.height == 1)
        #expect(second.pixels.count == 6)
        #expect(abs(Int(second.pixels[5].r) - 10) <= 1)
    }

    @Test
    func testOutputIsABGRA8TextureThatDownstreamCanSample() throws {
        let fixture = try Fixture()
        let processor = try LUTFrameProcessor(lut: .identity, device: fixture.device, queue: fixture.queue)
        let source = try fixture.makeSource(width: 2, height: 1, pixels: [(1, 2, 3), (4, 5, 6)])

        let result = try fixture.run(processor, on: source)

        #expect(result.output.pixelFormat == .bgra8Unorm)
        // 下游要拿它当片元纹理采样 ⇒ `.shaderRead` 必须在 usage 里
        #expect(result.output.usage.contains(.shaderRead))
    }

    // MARK: - 协议契约

    @Test
    func testProcessorIsIdentifiedSemanticallyAndOrderedBelowFutureProcessors() throws {
        let fixture = try Fixture()
        let processor = try LUTFrameProcessor(lut: .identity, device: fixture.device, queue: fixture.queue)

        #expect(processor.identifier == "lut")
        #expect(processor.order == 100)
    }

    @Test
    func testCustomIdentifierAndOrderAreHonoured() throws {
        let fixture = try Fixture()
        let processor = try LUTFrameProcessor(
            lut: .identity, device: fixture.device, queue: fixture.queue, identifier: "lut.night", order: 20
        )

        #expect(processor.identifier == "lut.night")
        #expect(processor.order == 20)
    }

    /// 把处理器真的插进 `FramePipeline` 跑一遍：证明两个模块的协议是**接得上**的，
    /// 而不只是各自能编译。
    @Test
    func testRunsInsideTheFramePipeline() throws {
        let fixture = try Fixture()
        let processor = try LUTFrameProcessor(lut: try Self.invertLUT(), device: fixture.device, queue: fixture.queue)
        let pipeline = FramePipeline<MTLTexture>(processors: [processor])
        let source = try fixture.makeSource(width: 1, height: 1, pixels: [(0, 255, 0)])

        let output = pipeline.submit(
            source, context: FrameContext(index: 0, width: 1, height: 1)
        )

        #expect(output.applied.map(\.identifier) == ["lut"])
        #expect(output.isFresh)
        let pixel = try #require(try fixture.readBack(output.frame).first)
        #expect(abs(Int(pixel.r) - 255) <= 2, "绿像素反相后红通道应接近 255，实际 \(pixel.r)")
        #expect(abs(Int(pixel.g) - 0) <= 2)
    }
}
