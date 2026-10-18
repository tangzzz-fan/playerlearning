import Foundation
import Metal
import PlayerCore

public enum MetalProcessorError: Error, CustomStringConvertible {
    case shader(String)
    case pipeline(String)
    case texture(width: Int, height: Int)
    case lut(size: Int)

    public var description: String {
        switch self {
        case .shader(let message): return "处理器着色器编译失败：\(message)"
        case .pipeline(let message): return "处理器渲染管线创建失败：\(message)"
        case .texture(let width, let height): return "处理器输出纹理分配失败：\(width)x\(height)"
        case .lut(let size): return "LUT 纹理分配失败：\(size)³（超过设备上限？）"
        }
    }
}

/// **一趟全屏 pass** 的通用外壳：进来一张 `MTLTexture`，出去另一张。
///
/// 这是"GPU 处理器"的公共部分 —— 到 `LUTFrameProcessor` 这里，真正属于 LUT 的只有
/// 着色器里的四行与一张 3D 纹理。深度估计、打码、放大都共用这一层外壳。
///
/// ## 队列必须与上屏是**同一个**（这条会静默出错）
/// 本类**提交后不等待**（`waitUntilCompleted` 会把"处理器慢"变成"播放卡"，
/// 那正是这条链路要避免的）。不等待的前提是 **Metal 保证同一队列内按提交顺序执行** ——
/// 于是"处理器那一趟 pass"一定排在"用它的结果上屏"之前。
///
/// 换一条队列，这个保证就没了：上屏那边可能在处理器还没写完时就开始采样，
/// 表现是**偶发的一帧花屏/旧画面**，且与负载相关 —— 这种 bug 没有稳定的复现条件，
/// 只能靠约定避免。所以调用方请把上屏用的 `MTLCommandQueue` 传进来
/// （`MPVRenderOutput.processingQueue`）。
///
/// ## 为什么不用信号量做三缓冲
/// 环形池 + 同队列有序已经够用：第 N 帧的结果被第 N+1/N+2 帧拿去上屏时，
/// 那些上屏命令都排在同一队列里、在本帧之后提交。再加信号量只会让 CPU 等 GPU。
///
/// ⚠️ **未验证**：4K 下的实际帧率、以及环形池深度取 3 是否最优 —— 一个真实处理器
/// 也没在真机上接过，这一层的性能数字都还没有（`docs/34` §六）。
public final class MetalPassProcessor: FrameProcessor {
    public typealias Frame = MTLTexture

    public let identifier: String
    public let order: Int
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let outputPixelFormat: MTLPixelFormat

    /// 最近一趟 pass 的命令缓冲。诊断与测试用（想等它落地就 `waitUntilCompleted`）——
    /// **产品路径不读它**，读了就等于把"不等待"这条约定破坏掉。
    public private(set) var lastCommandBuffer: MTLCommandBuffer?

    /// 提交之后是否**等 GPU 真的落地**。默认 `false`。
    ///
    /// 打开它只为一件事：**量测**。不等待时 `step()` 的耗时里不含这一趟 pass 的 GPU 时间，
    /// 于是"接上处理器之后还能不能实时"会被量成"几乎零开销" —— 这是最容易自欺的一种读数，
    /// 和"`swift build` 过就以为能用"是同一类错（`P-096`）。
    public var waitsForCompletion = false

    private let pipelineState: MTLRenderPipelineState
    /// 子类的额外绑定（LUT 的纹理与参数都在这里绑）。
    private let configure: (MTLRenderCommandEncoder, FrameContext) -> Void

    /// 环形池深度。3 与 `MPVRenderOutput` 的 `CVPixelBuffer` 池一致；
    /// 取多少都不会阻塞 CPU（见类注释），多一张的代价只是一份 4K 纹理的显存。
    private static let poolDepth = 3
    private var outputs: [MTLTexture] = []
    private var outputSize = (width: 0, height: 0)
    private var outputIndex = 0

    /// - Parameters:
    ///   - fragmentSource: 只需要写 **fragment** 那一段。顶点着色器由本类内置
    ///     （全屏四边形，`vertex_id` 直接生成，不要顶点缓冲），
    ///     并在片元源之前拼接，所以片元里可以直接用 `PassOut` 这个结构 ——
    ///     **不要自己再定义同名结构**。
    ///   - fragmentFunction: 片元函数名。
    ///   - configure: 额外的 `setFragmentTexture` / `setFragmentBytes`。
    public init(
        identifier: String,
        order: Int,
        device: MTLDevice,
        queue: MTLCommandQueue,
        fragmentSource: String,
        fragmentFunction: String,
        outputPixelFormat: MTLPixelFormat = .bgra8Unorm,
        configure: @escaping (MTLRenderCommandEncoder, FrameContext) -> Void = { _, _ in }
    ) throws {
        self.identifier = identifier
        self.order = order
        self.device = device
        self.queue = queue
        self.outputPixelFormat = outputPixelFormat
        self.configure = configure

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.vertexSource + "\n" + fragmentSource, options: nil)
        } catch {
            throw MetalProcessorError.shader("\(error)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: Self.vertexFunctionName)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        descriptor.colorAttachments[0].pixelFormat = outputPixelFormat
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalProcessorError.pipeline("\(error)")
        }
    }

    // MARK: - FrameProcessor

    public func process(_ frame: MTLTexture, context: FrameContext) -> FrameProcessorOutput<MTLTexture> {
        guard frame.width > 0, frame.height > 0 else { return .unchanged }
        guard let output = output(width: frame.width, height: frame.height),
              let buffer = queue.makeCommandBuffer()
        else { return .unchanged }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        // 整张四边形铺满目标 ⇒ 每个像素都会被写，没必要先清一遍（4K 下这是一次白送的带宽）。
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return .unchanged }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(frame, index: 0)
        configure(encoder, context)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.commit()
        lastCommandBuffer = buffer
        if waitsForCompletion {
            buffer.waitUntilCompleted()
        }
        return .replaced(output)
    }

    // MARK: - 资源

    /// 取一块这次能写的输出纹理。
    ///
    /// 尺寸变了就整池重建 —— 复用旧尺寸的纹理会被当 render target 直接拒绝
    /// （Metal validation 报一句 pipeline 错，日志里看不出是尺寸问题）。
    private func output(width: Int, height: Int) -> MTLTexture? {
        if outputs.isEmpty || outputSize != (width, height) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: outputPixelFormat, width: width, height: height, mipmapped: false
            )
            // 下游要采样它 ⇒ shaderRead；我们自己要画进去 ⇒ renderTarget。
            descriptor.usage = [.shaderRead, .renderTarget]
            // `.private`：只在 GPU 之间传递，CPU 从不直接读。读回是测试与取证的事，
            // 它们自己 blit 到 `.shared` —— 播放路径上不该为"能被读"付代价。
            descriptor.storageMode = .private
            descriptor.mipmapLevelCount = 1
            outputs = (0 ..< Self.poolDepth).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            outputSize = (width, height)
            outputIndex = 0
            guard !outputs.isEmpty else { return nil }
        }
        let texture = outputs[outputIndex % outputs.count]
        outputIndex += 1
        return texture
    }

    // MARK: - 着色器

    static let vertexFunctionName = "pass_vertex"

    /// 全屏四边形 + 与目标同向的 UV。UV **不翻转**：NDC 的 y 向上，帧纹理的 y 向下，
    /// 于是顶端（y = +1）对应 v = 0，画面朝向与源一致 —— 翻转了就会上下颠倒，
    /// 而这种错在对称的测试图上完全看不出来。
    private static let vertexSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PassOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex PassOut pass_vertex(uint vid [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
        };
        PassOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = float2((positions[vid].x + 1.0) * 0.5, (1.0 - positions[vid].y) * 0.5);
        return out;
    }
    """
}
