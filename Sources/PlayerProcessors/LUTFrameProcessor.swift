import Foundation
import Metal
import PlayerCore

/// **第一个真实的帧处理器**：把一张 `.cube` LUT 跑在 GPU 上。
///
/// 选它当第一个不是因为"调色好玩"，而是因为它把三件事一次钉住：
///
/// | 要证的事 | LUT 怎么证 |
/// | --- | --- |
/// | pass 真的在跑 | 反相 LUT 输出的每个像素都是 `255 - 输入` |
/// | 结果真的被下游用了 | 插值口径与 `ColorLUT.sample` 逐点对账（`testGPUMatchesTheCPUReferenceOnEverySample`） |
/// | 顺序 / 迟到策略接得上 | 它就是一个普通 `FrameProcessor`，`FramePipeline` 里跑得通 |
///
/// ## 为什么用 3D 纹理而不是"贴片 + 手工插值"
/// 三维纹理的 `filter::linear` 就是**硬件三线性**，一次采样等于 CPU 侧那八次乘加。
/// 贴片方案（把 N³ 铺成 N×N 的二维图）要自己在着色器里做两次 lerp，
/// 而那段代码一旦与 CPU 侧口径不一致，画面会"只是有点偏色" —— 最难查的那类错。
public final class LUTFrameProcessor: FrameProcessor {
    public typealias Frame = MTLTexture

    public let identifier: String
    public let order: Int
    /// 这张 LUT 的边长（2…129）。GPU 侧靠它算采样坐标，与 CPU 侧同一口径。
    public let dimension: Int

    /// 混合强度：0 = 原样（等于没接），1 = 全量。
    ///
    /// 为什么要有它：现场经常要"调一半"，而**重建处理器**会让 `FramePipeline`
    /// 清掉上一次结果（`setProcessors` 里 `reset()`）—— 拖动强度时画面会闪一下。
    /// 强度做成可变属性，拖动就是连续的变化。
    public var strength: Float {
        get { settings.strength }
        set { settings.strength = min(max(newValue, 0), 1) }
    }

    /// 最近一趟 pass 的命令缓冲（诊断 / 测试用，产品路径不读）。
    public var lastCommandBuffer: MTLCommandBuffer? { pass.lastCommandBuffer }

    /// 见 `MetalPassProcessor.waitsForCompletion`：**只为量测**打开它。
    public var waitsForCompletion: Bool {
        get { pass.waitsForCompletion }
        set { pass.waitsForCompletion = newValue }
    }

    private let pass: MetalPassProcessor
    private let lutTexture: MTLTexture
    private let settings: Settings

    /// `init` 期间要跨语句共享的可变状态。用类而不是 `var`：
    /// 着色器的 `configure` 闭包要**长期**读它（拖动强度），捕获一个值就改不动了。
    private final class Settings {
        let dimension: Int
        var strength: Float

        init(dimension: Int, strength: Float) {
            self.dimension = dimension
            self.strength = strength
        }
    }

    /// 与 MSL 里的 `struct LUTUniforms` 逐字段对应（两个 `float`，共 8 字节）。
    private struct Uniforms {
        var dimension: Float
        var strength: Float
    }

    /// - Parameters:
    ///   - queue: **必须与上屏用的是同一个队列**（理由见 `MetalPassProcessor` 的类注释）。
    ///   - identifier: 换 LUT 但坚持用同一个名字，会让旧的中间结果被误认成新表的结果 ——
    ///     要么换名字，要么走 `FramePipeline.setProcessors`（它会 `reset`）。
    public init(
        lut: ColorLUT,
        device: MTLDevice,
        queue: MTLCommandQueue,
        identifier: String = "lut",
        order: Int = 100,
        strength: Float = 1
    ) throws {
        let texture = try Self.makeLUTTexture(lut: lut, device: device)
        let settings = Settings(dimension: lut.dimension, strength: min(max(strength, 0), 1))
        self.identifier = identifier
        self.order = order
        self.dimension = lut.dimension
        self.lutTexture = texture
        self.settings = settings
        self.pass = try MetalPassProcessor(
            identifier: identifier,
            order: order,
            device: device,
            queue: queue,
            fragmentSource: Self.fragmentSource,
            fragmentFunction: Self.fragmentFunction
        ) { encoder, _ in
            encoder.setFragmentTexture(texture, index: 1)
            var uniforms = Uniforms(
                dimension: Float(settings.dimension),
                strength: settings.strength
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        }
    }

    public func process(_ frame: MTLTexture, context: FrameContext) -> FrameProcessorOutput<MTLTexture> {
        pass.process(frame, context: context)
    }

    // MARK: - LUT 纹理

    /// 把 LUT 塞进一张 `rgba16Float` 的三维纹理。
    ///
    /// 为什么是 half 不是 float：**半精度浮点的线性过滤是核心能力**，32 位浮点的过滤
    /// 在部分设备上要么不支持、要么要查 `supports32BitFloatFiltering`。11 位有效位
    /// 对 8 位输出绰绰有余，没必要为此引入设备差异。
    private static func makeLUTTexture(lut: ColorLUT, device: MTLDevice) throws -> MTLTexture {
        let dimension = lut.dimension
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = dimension
        descriptor.height = dimension
        descriptor.depth = dimension
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        // `replace` 需要 CPU 可写。
        // ⚠️ `.managed` **在 iOS 上不是一个可用值**（不是"运行时不可用"，是编译期就没这个 case），
        // 写成 `hasUnifiedMemory ? .shared : .managed` 这种三元式在 macOS 上能过、在 iOS 上直接
        // 编译失败（`P-099`）。所以这里必须用条件编译分开，不能在表达式里"通用化"。
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalProcessorError.lut(size: dimension)
        }

        let count = dimension * dimension * dimension
        var packed = [Float16](repeating: 0, count: count * 4)
        for index in 0 ..< count {
            packed[index * 4] = Float16(lut.values[index * 3])
            packed[index * 4 + 1] = Float16(lut.values[index * 3 + 1])
            packed[index * 4 + 2] = Float16(lut.values[index * 3 + 2])
            packed[index * 4 + 3] = 1
        }
        let bytesPerPixel = 8 // rgba16Float
        texture.replace(
            region: MTLRegionMake3D(0, 0, 0, dimension, dimension, dimension),
            mipmapLevel: 0,
            slice: 0,
            withBytes: packed,
            bytesPerRow: dimension * bytesPerPixel,
            bytesPerImage: dimension * dimension * bytesPerPixel
        )
        return texture
    }

    // MARK: - 着色器

    private static let fragmentFunction = "lut_fragment"

    /// 坐标换算 `(base * (n - 1) + 0.5) / n` 是**唯一**容易写错的一行：
    ///
    /// 归一化坐标 `c` 落在"第 `c * n - 0.5` 个节点"上，而我们想要的节点位置是
    /// `base * (n - 1)`。反解出 `c = (base * (n - 1) + 0.5) / n`。
    ///
    /// 少了 `+ 0.5` 就会整体偏半个节点 —— 表现是"暗部偏一点、亮部偏一点"，
    /// 在对称的测试图上根本看不出来，只有拿中灰（0.5）跟 CPU 对账才抓得到。
    private static let fragmentSource = """
    struct LUTUniforms {
        float dimension;
        float strength;
    };

    fragment float4 lut_fragment(PassOut in [[stage_in]],
                                 texture2d<float> source [[texture(0)]],
                                 texture3d<float> lut [[texture(1)]],
                                 constant LUTUniforms &uniforms [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

        float4 color = source.sample(linearSampler, in.uv);
        float3 base = clamp(color.rgb, 0.0, 1.0);
        float n = uniforms.dimension;
        float3 coordinate = (base * (n - 1.0) + 0.5) / n;
        float3 mapped = lut.sample(linearSampler, coordinate).rgb;
        return float4(mix(base, mapped, uniforms.strength), color.a);
    }
    """
}
