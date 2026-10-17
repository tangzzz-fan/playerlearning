#if os(iOS)
import CoreText
import CoreVideo
import Foundation
import Libmpv
import Metal
import PlayerCore
import PlayerUI
import QuartzCore
import UIKit

/// **render API 那条路的"显示"实现**：帧先到我们手里，再由图层的拥有者自己画上去。
///
/// 与 `WindowEmbedOutput` 的关系是**并存**，不是替换（`docs/24` §四）：
/// - `WindowEmbedOutput` 把 `wid` 交给播放器，帧由 mpv 自己画进这个图层；
/// - 本类**不设 `wid`**（内核被要求 `vo=libmpv`），每帧由 `mpv_render_context_render`
///   写进一块 **IOSurface 支撑的 `CVPixelBuffer`**，再由 Metal 画进这个图层。
///
/// 为什么值得多这一层拷贝：只有帧落到我们手里，**自绘字幕 / 滤镜 / 全景 / 3D / 逐帧截图**
/// 才存在实现的位置（`P4-T3` 的触发条件）。用拷贝换能力，这是这条线的全部交易。
///
/// ## 线程
/// 全部在主线程。`mpv_render_context_*` 要求"同一个线程调用"，
/// 而本类的驱动源是主线程的 `CADisplayLink` —— 建上下文（`attach`）与每帧渲染因而是同一线程。
///
/// `@unchecked Sendable` 的理由：类本身是 `@MainActor` 隔离的（所有状态都由主线程独占），
/// 但父类 `CALayer` 不是 `Sendable` ⇒ 编译器不会自动推断，而内核（actor）需要把这个引用
/// **还给主线程**。这里不给编译器"我在绕过检查"的错觉：真正要保证的事只有一条 ——
/// 除了 `attach` / `detach` / `layout` 这几个明确的主线程入口，别处一律不碰它。
@MainActor
public final class MPVRenderOutput: CAMetalLayer, VideoOutputProtocol, VideoSurface, @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case noDevice
        case noQueue
        case noTextureCache
        case shader(String)
        case pipeline(String)

        public var description: String {
            switch self {
            case .noDevice: return "没有可用的 Metal 设备（模拟器/真机都不该发生）"
            case .noQueue: return "makeCommandQueue 失败"
            case .noTextureCache: return "CVMetalTextureCacheCreate 失败"
            case .shader(let message): return "着色器编译失败：\(message)"
            case .pipeline(let message): return "渲染管线创建失败：\(message)"
            }
        }
    }

    /// **`nil` 是这条路的本质**：我们没有句柄可以交出去，帧由我们自己画（`VideoOutputKind.renderAPI`）。
    public nonisolated var windowEmbedHandle: Int64? { nil }

    /// 每帧的耗时分布（`docs/24` §四 第 3 步的数据来源）。
    public private(set) var timings = FrameTimingStats(count: 0, p50: 0, p95: 0, max: 0, mean: 0)
    /// mpv 自己那次 SW 渲染的耗时 —— 与 `timings` 分开，因为"慢在 mpv"和"慢在我们"要分开归因。
    public private(set) var renderTimings = FrameTimingStats(count: 0, p50: 0, p95: 0, max: 0, mean: 0)
    /// 累计上屏帧数（bench 用来判断"到底画了几帧"）。
    public private(set) var presentedFrames = 0
    /// 最近一次渲染用的尺寸（像素）。
    public private(set) var lastVideoSize: CGSize = .zero

    /// **上屏取证**：把三层各读回一小块，算非黑像素占比。
    ///
    /// 为什么需要它：`presentedFrames` 只证明"`present` 被调用过"，**不证明屏幕上真有画面**。
    /// 截图能当证据，但它有一个致命弱点 —— **它只回答"最终屏幕上是什么"**，
    /// 一旦是黑的，你分不清是 mpv 没写、纹理没生成、还是着色器没画。
    /// 三层读数（`cpu` / `source` / `drawable`）就是为了把这三段拆开。
    ///
    /// ⚠️ **采样框取画面中心，不取左上角**。这不是审美选择：本机素材（2.39:1）
    /// 上下自带黑边，左上角的 96×54 正好落在黑条里 —— 于是"画面正常"会被读成 0.000。
    /// 这个坑让第一版取证把"真机其实是好的"误判成"真机全黑"，查了六轮（`P-094`）。
    ///
    /// 默认关：读回要 `waitUntilCompleted`，是**同步等 GPU**，不该出现在播放路径上。
    ///
    /// 打开时会把 `framebufferOnly` 关掉 —— 否则 drawable 的纹理**不允许被读**，
    /// blit 会静默失败、读回永远是 0.000。
    public var verifiesOnScreen = false {
        didSet { framebufferOnly = !verifiesOnScreen }
    }

    /// 最近一次从 **drawable** 读回的非黑像素占比（`-1` = 读不回来，别当成"黑"）。
    public private(set) var lastOnScreenNonBlackRatio: Double = 0
    /// 读回的采样区域尺寸 —— 写进日志，避免"占比变了其实是因为采样框变了"（`P-082` 同族）。
    public private(set) var onScreenSampleSize = CGSize.zero
    /// drawable 的真实像素尺寸。**它和 `bounds` 不是一回事**，真机上出问题时先看这个。
    public private(set) var drawablePixelSize = CGSize.zero
    /// CPU 侧（mpv 刚写完、还没 unlock）的非黑占比 —— 分辨"mpv 没写"与"写了但 GPU 看不见"。
    public private(set) var cpuNonBlackRatio: Double = 0
    /// 这一帧 `CVPixelBuffer` 的真实行宽（`GetBytesPerRow` 会按对齐抬高，不等于 宽 × 4）。
    public private(set) var cpuStride = 0
    /// 最近一次 `mpv_render_context_update` 的原始标志位（`MPV_RENDER_UPDATE_FRAME` 是否置位）。
    public private(set) var updateFlags: UInt64 = 0
    /// 最近一次 `mpv_render_context_render` 的返回值。
    public private(set) var lastRenderStatus: Int32 = 0

    /// 按什么尺寸渲染（软件后端的成本与**目标像素数**成正比，与源分辨率无关）。
    public enum RenderTarget: String, Sendable {
        /// 按**源码尺寸**渲染，再缩到图层：像素最忠实，代价随源码分辨率线性上涨。
        case native
        /// 按**上屏尺寸**渲染（等比、不放大）：4K 源在手机屏上与 1080p 同价。
        case drawable
    }

    /// 默认按上屏尺寸 —— 用户看不到的像素不该让 CPU 去画。
    public var renderTarget: RenderTarget = .drawable {
        didSet { redrawFlag.set() }
    }

    /// 调试用：**强制**按这个尺寸渲染（不管源码多大、图层多大）。
    ///
    /// 它的用途是把两件事分开：「尺寸/缩放的锅」与「CVPixelBuffer 的锅」。
    /// 真机上 probe 用 640×360 出得了画，而上屏那条用 1205×678 —— 差的就是尺寸。
    public var forcedRenderSize: CGSize? {
        didSet { redrawFlag.set() }
    }

    /// 片元效果。切换后需要重画一帧才看得到 —— 调试入口切换时本类会自动请求重画。
    public var effect: VideoEffect = .none {
        didSet { redrawFlag.set() }
    }

    /// **自绘字幕的数据源**（`PlayerCore.SubtitleOverlaySource`）。设了它之后，
    /// 每帧用 mpv 的 `time-pos` 查一次该显示什么，再交给叠加层去画。
    ///
    /// 与 mpv 自己画字幕**会重复**：那条路把字幕烧进帧里，我们这条再画一遍。
    /// 正式用的时候要么关 mpv 的字幕（`sub-visibility=no`），要么关这条 —— 不能都开。
    public var subtitleSource: SubtitleOverlaySource? {
        didSet {
            liveSubtitleText = nil
            overlayDirty = true
            redrawFlag.set()
        }
    }
    /// 上一次真正设进叠加层的文本 —— 用来**只在内容变化时**重建纹理。
    private var liveSubtitleText: String?

    /// 自绘叠加层（**字幕机制的第一版**：由我们画字、合成到帧上，而不是 mpv 画）。
    public var overlayText: String? {
        didSet {
            guard overlayText != oldValue else { return }
            overlayDirty = true
            redrawFlag.set()
        }
    }

    private let metalDevice: MTLDevice
    private let queue: MTLCommandQueue
    private let videoPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var session: MPVSWSession?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?

    /// 环形缓冲：GPU 还在读上一帧时，mpv 已经开始写下一帧 —— 单缓冲会撕裂。
    private var buffers: [CVPixelBuffer] = []
    private var bufferIndex = 0
    private var bufferSize = CGSize.zero
    /// 必须持有到命令缓冲提交之后：`CVMetalTextureGetTexture` 得到的纹理不保证自己抓着 IOSurface。
    private var retainedTexture: CVMetalTexture?
    private var overlayTexture: MTLTexture?
    private var overlayDirty = true

    private let updateFlag = RenderFlag()
    /// "请求重画"也用同一个跨线程标记：`layout` 必须是 `nonisolated`（见下），
    /// 而它唯一的副作用就是"尺寸变了，重画一帧"。
    private let redrawFlag = RenderFlag()
    private var timingRecorder = FrameTimingRecorder()
    private var renderRecorder = FrameTimingRecorder()

    private let log: (String) -> Void
    private let bridge: MPVRenderBridge

    public init(bridge: MPVRenderBridge, log: @escaping (String) -> Void = { _ in }) throws {
        self.bridge = bridge
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        guard let queue = device.makeCommandQueue() else { throw Failure.noQueue }
        metalDevice = device
        self.queue = queue
        self.log = log
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw Failure.shader("\(error)")
        }
        videoPipeline = try Self.makePipeline(library, fragment: "video_fragment", blending: false)
        overlayPipeline = try Self.makePipeline(library, fragment: "overlay_fragment", blending: true)
        super.init()
        configure()
        bridge.registerAttach { [weak self] in try self?.attachIfNeeded() }
        bridge.registerDetach { [weak self] in self?.detach() }
    }

    public required init?(coder: NSCoder) {
        fatalError("MPVRenderOutput 只支持代码构造")
    }

    public override init(layer: Any) {
        fatalError("MPVRenderOutput 不支持图层拷贝")
    }

    // MARK: - 生命周期

    /// 内核把句柄放到交接点上之后，由本类在**自己的主线程拍子里**取走并建上下文。
    ///
    /// 为什么不是内核直接调过来：`mpv_render_context_*` 要求"同一个线程"，
    /// 而渲染驱动是主线程的 `CADisplayLink` —— 那就只能由主线程自己去建。
    /// 晚一拍（≈8–16 ms）换掉一次跨隔离域的传递，值得。
    private func attachIfNeeded() throws {
        guard session == nil, let handle = bridge.take() else { return }
        let session = try MPVSWSession(handle: handle.pointer)
        // 回调来自 **mpv 的线程** ⇒ 只能置个标记，渲染留给主线程（见类注释的线程纪律）。
        let flag = updateFlag
        session.setUpdates { flag.set() }
        self.session = session
        startDisplayLink()
        log("[render] attach 完成 · 后端=sw · 驱动=CADisplayLink")
    }

    /// 断开并释放渲染上下文。**必须在句柄销毁之前调用**（上下文挂在句柄上）。
    public func detach() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        // 先释放上下文，再丢会话 —— 顺序反过来时 deinit 里的 free 仍会执行，但回调已摘，等价。
        session = nil
        buffers = []
        bufferSize = .zero
        retainedTexture = nil
        overlayTexture = nil
    }

    public func resetTimings() {
        timingRecorder = FrameTimingRecorder()
        renderRecorder = FrameTimingRecorder()
        presentedFrames = 0
    }

    /// 渲染上下文建好了没有。内核用它判断"这一次 load 要不要 attach"。
    public var isAttached: Bool { session != nil }

    public func publishTimings() {
        timings = timingRecorder.stats()
        renderTimings = renderRecorder.stats()
    }

    // MARK: - VideoSurface

    /// `nonisolated`（协议不标 actor，而它是 `CALayer` 的属性操作）——
    /// 它只在主线程被调用（`UIView.layoutSubviews` / `NSView.layout`），
    /// 但整段不碰任何隔离状态：只写 `CALayer` 自己的属性 + 置一个跨线程标记。
    public nonisolated func layout(in bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        frame = bounds
        contentsScale = scale
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if pixelSize.width > 1, pixelSize.height > 1 {
            drawableSize = pixelSize
            redrawFlag.set()
        }
    }

    // MARK: - 渲染

    /// 主线程的一拍：有新帧就渲染 + 上屏。
    ///
    /// `force` 让 bench 能"不依赖 mpv 是否认为有新帧"地连续压帧 ——
    /// 否则测到的是"有内容的帧有多少"，而不是"渲染这一帧要多久"。
    public func step(force: Bool = false) {
        if session == nil {
            do {
                try attachIfNeeded()
            } catch {
                // 建上下文失败只可能是底层拒绝（后端/驱动），**必须吼出来**：
                // 否则用户看到的就是"一直黑屏"，而日志里什么都没有。
                log("[render] 建渲染上下文失败：\(error)")
                redrawFlag.take()
                return
            }
        }
        guard let session else { return }
        let flags = session.update()
        let frameAvailable = flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
        updateFlags = flags
        let redraw = redrawFlag.take()
        guard force || frameAvailable || updateFlag.take() || redraw else { return }
        if force { _ = updateFlag.take() }

        // 自绘字幕：**按 mpv 的 time-pos 对表**，不是按帧计数、也不是按墙钟。
        // 只在文本真的变了时才重建叠加层纹理（`overlayText` 的 didSet 会置脏位）。
        if let subtitleSource, let position = session.timePosition() {
            let text = subtitleSource.text(at: position)
            if text != liveSubtitleText {
                liveSubtitleText = text
                overlayText = text
            }
        }
        guard let size = session.videoSize() else { return }
        lastVideoSize = CGSize(width: size.width, height: size.height)
        guard let drawable = nextDrawable() else { return }
        // 软件后端按"目标尺寸"干活：给它多少像素，它就缩放到多少像素。
        // 于是 4K 源在 1206×678 的图层上只花 1080p 的钱（实测见 `docs/25` §三）。
        let target = forcedRenderSize.map { (width: Int($0.width), height: Int($0.height)) } ?? (renderTarget == .native ? size : {
            let scaled = VideoFitRect.scaledSize(
                content: CGSize(width: size.width, height: size.height),
                in: CGSize(width: drawable.texture.width, height: drawable.texture.height)
            )
            return (width: Int(scaled.width), height: Int(scaled.height))
        }())
        guard let buffer = buffer(width: target.width, height: target.height) else { return }

        let clock = ContinuousClock()
        let started = clock.now
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return
        }
        // mpv **直接写进 IOSurface**：没有再经过一个 `[UInt8]` 中转数组，
        // 这是"软件后端"这条路上唯一能省下的那次拷贝。
        let probeThisFrame = verifiesOnScreen && (presentedFrames + 1) % 30 == 0
        let probeStride = CVPixelBufferGetBytesPerRow(buffer)
        let status = session.render(
            into: base,
            width: target.width,
            height: target.height,
            stride: probeStride
        )
        lastRenderStatus = status
        let rendered = clock.now
        if verifiesOnScreen, (presentedFrames + 1) % 30 == 0 {
            // CPU 侧的读数：**就在 unlock 之前**直接看 mpv 写进这块内存的东西。
            // 三层读数一起比，才能回答"是谁把画面弄丢了"：
            //   cpu  = mpv 到底写没写进去（这一层黑 ⇒ mpv 没写）
            //   source = IOSurface → Metal 纹理这一步通不通
            //   drawable = 着色器有没有画上去
            let sampleWidth = min(96, target.width)
            let sampleHeight = min(54, target.height)
            cpuNonBlackRatio = Self.nonBlackRatio(
                base: base,
                originX: (target.width - sampleWidth) / 2,
                originY: (target.height - sampleHeight) / 2,
                width: sampleWidth, height: sampleHeight, stride: probeStride
            )
            cpuStride = probeStride
        }
        // **先 `unlock` 再建纹理**。理由是按 Apple 的语义：`CVPixelBufferUnlockBaseAddress`
        // 对 IOSurface 支撑的 buffer 除了解锁，还要把 CPU 写入同步到 GPU 可见处，
        // 而 `CVMetalTextureCacheCreateTextureFromImage` 一拿到纹理，GPU 就可能立刻开始读。
        //
        // ⚠️ 不要把这句读成"顺序反了就会黑屏"。**本机没有测到那个结论**：
        // 实测（真机 iPhone 16 Pro）两种顺序都能出画。保留这个顺序是因为它符合语义，
        // 不是因为它修了一个已经观察到的 bug —— 把"预防"写成"修好了什么"就是假归因（`P-083`）。
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard status >= 0 else {
            log("[render] mpv_render_context_render 失败 status=\(status) \(String(cString: mpv_error_string(status)))")
            return
        }
        guard let texture = makeTexture(from: buffer, width: target.width, height: target.height) else { return }

        draw(
            texture: texture,
            drawable: drawable,
            content: CGSize(width: target.width, height: target.height),
            sampleAfterDraw: verifiesOnScreen && (presentedFrames + 1) % 30 == 0
        )
        let finished = clock.now
        renderRecorder.record(milliseconds: Self.milliseconds(rendered - started))
        timingRecorder.record(milliseconds: Self.milliseconds(finished - started))
        presentedFrames += 1
        publishTimings()
    }

    private func draw(texture: MTLTexture, drawable: CAMetalDrawable, content: CGSize, sampleAfterDraw: Bool = false) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // 摆放几何走 `VideoFitRect`（PlayerCore，已单测）：竖屏 / 宽银幕 / 尺寸未知
        // 这三种情形在这里是同一段代码，而不是三处 if。
        let rect = VideoFitRect.rect(
            content: content,
            in: CGSize(width: drawable.texture.width, height: drawable.texture.height),
            fit: .fit
        )
        let quad = Self.quad(in: rect, container: CGSize(width: drawable.texture.width, height: drawable.texture.height))

        encoder.setRenderPipelineState(videoPipeline)
        quad.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.setFragmentTexture(texture, index: 0)
        var effect = effect.shaderIndex
        encoder.setFragmentBytes(&effect, length: MemoryLayout<Int32>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // 自绘叠加层：**这就是"自己画字幕"的位置** —— 与帧无关的第二张纹理，
        // 由 CoreText 画好、按同样的矩形贴上去。
        if let overlay = overlayTexture(for: content) {
            encoder.setRenderPipelineState(overlayPipeline)
            quad.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            encoder.setFragmentTexture(overlay, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        drawablePixelSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)

        // ⚠️ 读回**必须在这个 command buffer 里、`present` 之前**。
        // `present` 一调，这张 drawable 就交还给系统了 —— 之后再 blit 读它，
        // 读到的是未定义的（真机实测：present 之后读恒为全黑，而 source 明明是 0.185）。
        // 这个错在模拟器上不会显形：那里两者的时序恰好还来得及。
        var readback: MTLTexture?
        let width = min(96, drawable.texture.width)
        let height = min(54, drawable.texture.height)
        if sampleAfterDraw, width > 0, height > 0 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: drawable.texture.pixelFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            if let target = metalDevice.makeTexture(descriptor: descriptor),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: drawable.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(
                        x: (drawable.texture.width - width) / 2,
                        y: (drawable.texture.height - height) / 2,
                        z: 0
                    ),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: target,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
                readback = target
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if let readback {
            commandBuffer.waitUntilCompleted()
            verifyOnScreen(drawableReadback: readback, source: texture, width: width, height: height)
        }
    }

    /// 把 drawable 的左上角一小块拷到可读纹理，算**非黑像素占比**。
    ///
    /// 这块区域是按**像素**取的，不是按比例 —— 于是同一段素材、同一套着色器下，
    /// 模拟器与真机的数字可以直接比（`P-082`：计数型判据必须连口径一起说）。
    /// 采样框 96×54 覆盖 16:9 的一角；2.39:1 的素材在那里可能是黑边，
    /// 所以判据是 **> 0**（有内容）而不是"必须多亮" —— 判据要比事实弱一档（`P-088` 同族）。
    private func verifyOnScreen(drawableReadback: MTLTexture, source: MTLTexture, width: Int, height: Int) {
        // 三个读数一起打，回答"是谁把画面弄丢了"：
        //   cpu   = mpv 到底写没写进那块内存（在 unlock 之前直接数）
        //   source = IOSurface → Metal 纹理通不通
        //   drawable = 着色器有没有画上去
        let sourceRatio = readBack(
            source,
            originX: max(0, (source.width - width) / 2),
            originY: max(0, (source.height - height) / 2),
            width: width, height: height
        )
        let drawableRatio = Self.nonBlackRatio(texture: drawableReadback)

        lastOnScreenNonBlackRatio = drawableRatio
        onScreenSampleSize = CGSize(width: width, height: height)
        log(
            "[render] 上屏取证 cpu非黑=\(Self.ratioText(cpuNonBlackRatio))"
                + " source非黑=\(Self.ratioText(sourceRatio))"
                + " drawable非黑=\(Self.ratioText(drawableRatio))"

                + " flags=\(updateFlags) status=\(lastRenderStatus)"
                + " 采样=\(width)x\(height) stride=\(cpuStride)"
                + " drawable=\(Int(drawablePixelSize.width))x\(Int(drawablePixelSize.height))"
        )
    }

    /// 直接数一块 CPU 内存里的非黑像素（BGRA，按真实 `stride` 跳过行尾对齐填充）。
    private static func nonBlackRatio(
        base: UnsafeMutableRawPointer, originX: Int = 0, originY: Int = 0,
        width: Int, height: Int, stride: Int
    ) -> Double {
        guard width > 0, height > 0, stride >= width * 4 else { return -1 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var nonBlack = 0
        for row in 0 ..< height {
            let rowStart = (originY + row) * stride + originX * 4
            for column in 0 ..< width {
                let index = rowStart + column * 4
                if bytes[index] > 12 || bytes[index + 1] > 12 || bytes[index + 2] > 12 {
                    nonBlack += 1
                }
            }
        }
        return Double(nonBlack) / Double(width * height)
    }

    private static func ratioText(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "n/a"
    }

    /// 把一张纹理的左上角拷进可读纹理，算**非黑像素占比**。`nil` = 拷不出来（不是"黑"）。
    private static func nonBlackRatio(texture: MTLTexture) -> Double {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
            )
        }
        var nonBlack = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] > 12 || bytes[index + 1] > 12 || bytes[index + 2] > 12 {
                nonBlack += 1
            }
        }
        return Double(nonBlack) / Double(texture.width * texture.height)
    }

    private func readBack(_ texture: MTLTexture, originX: Int = 0, originY: Int = 0, width: Int, height: Int) -> Double? {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        // `.shared` 是真机上唯一能直接 `getBytes` 的存储模式（`.managed` 只有 macOS 有）。
        descriptor.storageMode = .shared
        guard let target = metalDevice.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: originX, y: originY, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: target,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        var nonBlack = 0
        // BGRA：任意分量 > 12 就算"非黑"。阈值 12 与取帧探针的诊断口径一致（不是随手挑的）。
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] > 12 || bytes[index + 1] > 12 || bytes[index + 2] > 12 {
                nonBlack += 1
            }
        }
        return Double(nonBlack) / Double(width * height)
    }

    // MARK: - 资源

    private func configure() {
        self.device = metalDevice
        framebufferOnly = true
        isOpaque = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
        pixelFormat = .bgra8Unorm
        // 显式 sRGB：不设时图层按设备空间解释，mpv 输出的 BT.709 会被二次转换，
        // 表现为"颜色发灰"——而"发灰"永远会被归因为"帧没取对"。
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &cache) == kCVReturnSuccess {
            textureCache = cache
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget(output: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkTarget = target
    }

    /// 取一块可写的像素缓冲（环形，避免"GPU 在读、mpv 在写"）。
    private func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if size != bufferSize || buffers.isEmpty {
            bufferSize = size
            buffers = (0 ..< 3).compactMap { _ in Self.makePixelBuffer(width: width, height: height) }
            bufferIndex = 0
            textureCache.map { CVMetalTextureCacheFlush($0, 0) }
        }
        guard !buffers.isEmpty else { return nil }
        let buffer = buffers[bufferIndex % buffers.count]
        bufferIndex += 1
        return buffer
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            // ⚠️ 这一条是"能建 Metal 纹理"的前提（`docs/24` §四 第 2 步要验证的正是它）。
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    private func makeTexture(from buffer: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
        guard let textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
        else { return nil }
        retainedTexture = cvTexture
        return texture
    }

    /// 叠加层纹理：CoreText 画字 → 位图 → 纹理。**只在文字/尺寸变化时重建**。
    private func overlayTexture(for content: CGSize) -> MTLTexture? {
        guard let text = overlayText, !text.isEmpty else { return nil }
        if !overlayDirty, overlayTexture?.width == Int(content.width), overlayTexture?.height == Int(content.height) {
            return overlayTexture
        }
        let width = Int(content.width)
        let height = Int(content.height)
        guard width > 0, height > 0 else { return nil }
        guard let bitmap = Self.makeOverlayBitmap(text: text, width: width, height: height) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = metalDevice.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0, withBytes: bitmap.data, bytesPerRow: width * 4
        )
        overlayTexture = texture
        overlayDirty = false
        return texture
    }

    /// 把一句字幕画成一张与视频同尺寸的透明位图（白色描边 + 底部居中）。
    ///
    /// 位置与字号都按**视频高度**取比例：写死像素值时，720p 上看着合适、4K 上细如发丝。
    private static func makeOverlayBitmap(text: String, width: Int, height: Int) -> (data: [UInt8], bytesPerRow: Int)? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let created = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))

            let fontSize = max(12, CGFloat(height) * 0.052)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let bottomInset = CGFloat(height) * 0.07
            let origin = CGPoint(
                x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                y: bottomInset
            )
            // 描边：不描边时白字压在亮画面上会消失 —— 字幕的第一条可用性要求。
            context.setShouldAntialias(true)
            context.setLineWidth(max(2, fontSize * 0.09))
            context.setLineJoin(.round)
            // ⚠️ 两遍绘制之间**必须重设 `textPosition`**：`CTLineDraw` 会把它**推进**到本行末尾，
            //    于是第二遍（填充）从第一遍结束的位置开始画 —— 表现是同一句话被并排画了两遍。
            //    实测就是这样：描边在前、填充在后，看起来像"字幕重复了一次"。
            context.textPosition = origin
            context.setFillColor(UIColor.black.withAlphaComponent(0.85).cgColor)
            context.setTextDrawingMode(.stroke)
            CTLineDraw(line, context)
            context.textPosition = origin
            context.setTextDrawingMode(.fill)
            context.setFillColor(UIColor.white.cgColor)
            CTLineDraw(line, context)
            return true
        }
        return created ? (data, width * 4) : nil
    }

    // MARK: - 几何 / 着色器

    private struct QuadVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    /// 4 个顶点（三角形带）：位置在 NDC，UV 左上角为 (0,0)。
    private static func quad(in rect: CGRect, container: CGSize) -> [QuadVertex] {
        guard container.width > 0, container.height > 0 else {
            return []
        }
        let left = Float(rect.minX / container.width * 2 - 1)
        let right = Float(rect.maxX / container.width * 2 - 1)
        // NDC 的 y 向上，图层的 y 向下 ⇒ 上下互换。
        let top = Float(1 - rect.minY / container.height * 2)
        let bottom = Float(1 - rect.maxY / container.height * 2)
        return [
            QuadVertex(position: SIMD2(left, top), uv: SIMD2(0, 0)),
            QuadVertex(position: SIMD2(right, top), uv: SIMD2(1, 0)),
            QuadVertex(position: SIMD2(left, bottom), uv: SIMD2(0, 1)),
            QuadVertex(position: SIMD2(right, bottom), uv: SIMD2(1, 1))
        ]
    }

    private static func makePipeline(
        _ library: MTLLibrary, fragment: String, blending: Bool
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "video_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        if blending {
            // 预乘 alpha：CoreText 画出来的位图就是预乘的 ⇒ 因子用 1 / (1-a) 而不是 srcAlpha。
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try library.device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.pipeline("\(error)")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    /// 与 `VideoEffect.shaderIndex` 严格对应（`VideoEffectTests` 钉住这两个数字）。
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadVertex {
        float2 position;
        float2 uv;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut video_vertex(uint vid [[vertex_id]], constant QuadVertex *quad [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(quad[vid].position, 0.0, 1.0);
        out.uv = quad[vid].uv;
        return out;
    }

    fragment float4 video_fragment(VertexOut in [[stage_in]],
                                   texture2d<float> frame [[texture(0)]],
                                   constant uint &effect [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float4 color = frame.sample(linearSampler, in.uv);
        if (effect == 1u) {
            float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
            color = float4(luma, luma, luma, color.a);
        }
        return color;
    }

    fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                     texture2d<float> overlay [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        return overlay.sample(linearSampler, in.uv);
    }
    """
}

/// 跨线程的"有新帧"标记。
///
/// 为什么不用 `@MainActor` 属性 + `Task { @MainActor in … }`：mpv 的更新回调要求**立刻返回**，
/// 而每帧都排一个 Task 会在渲染线程上堆任务 —— 表现是"越播越慢"，且看不出原因。
private final class RenderFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = false
        return current
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var output: MPVRenderOutput?

    init(output: MPVRenderOutput) {
        self.output = output
    }

    @objc func tick() {
        output?.step()
    }
}
#endif
