#if os(iOS)
import Foundation
import Libmpv
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 用 **render API（软件后端）** 从 libmpv 里把一帧像素**真的取出来**。
///
/// 存在的理由：`wid` 嵌入那条路上，帧**只存在于播放器内部**（被直接画到我们的图层），
/// 我们拿不到它 —— 于是"自绘字幕 / 滤镜 / 全景 / 3D / 逐帧截图"全都做不了。
/// 这是 `P4-T3` 留下的触发条件之一（"需自绘字幕"）落在工程上的第一步。
///
/// 为什么先做**软件后端**（`MPV_RENDER_API_TYPE_SW`）而不是 GPU：
/// GPU 那条（OpenGL ES / Vulkan→MoltenVK）要先有可用的 GL 上下文与 FBO，
/// 而 iOS 上 GL 已废弃、GLES 纹理转 Metal 又是一层桥 —— 它能在 iOS 上成立与否
/// **我们从未实测过**（`knowledge/K6` §3.2 标的就是这条）。
/// 软件后端是"必然能出帧"的那条：先用它把**帧的出口**打通、把像素拿到手上，
/// GPU 加速是后面替换实现的事，不影响上层对"帧"的用法。
///
/// 代价必须写在明处：**软件后端是 CPU 拷贝**，1080p 每帧约 8 MB，
/// 4K 每帧约 33 MB —— 够用来验证与做低频取帧，**不适合当高帧率渲染管线**。
public final class MPVRenderProbe {
    public struct Result: Sendable {
        public let width: Int
        public let height: Int
        public let renders: Int
        public let bestNonBlackRatio: Double
        public let pngPath: String?
    }

    public enum Failure: Error, CustomStringConvertible {
        case createHandle
        case setOption(String, Int32)
        case initialize(Int32)
        case renderContext(Int32)
        case render(Int32)
        case noFrame

        public var description: String {
            switch self {
            case .createHandle: return "mpv_create 失败"
            case .setOption(let name, let code): return "setOption(\(name)) 被拒：\(code)"
            case .initialize(let code): return "mpv_initialize：\(code)"
            case .renderContext(let code): return "mpv_render_context_create：\(code)"
            case .render(let code): return "mpv_render_context_render：\(code)"
            case .noFrame: return "等了 8 秒没有取到非黑帧"
            }
        }
    }

    private var handle: OpaquePointer?
    /// 渲染上下文收敛到 `MPVSWSession`：它与上屏那条路（`MPVRenderOutput`）**只差最后一步**，
    /// 建上下文 / 问尺寸 / 写内存完全一样，各写一遍只会漂。
    private var session: MPVSWSession?

    /// mpv 自己的日志出口。取不到帧时**先听它说**，比在属性上猜快得多。
    public var log: ((String) -> Void)?

    public init(log: ((String) -> Void)? = nil) throws {
        self.log = log
        guard let created = mpv_create() else { throw Failure.createHandle }
        handle = created
        // 与 `wid` 那条路的关键差别：**不设 wid**、`vo` 用 `libmpv`（渲染由我们驱动）。
        try option("vo", "libmpv")
        // 硬解在软件后端下没有意义（解出来的帧还要回 CPU）⇒ 显式关掉，避免"以为省了"。
        try option("hwdec", "no")
        try option("terminal", "no")
        try option("idle", "yes")
        try option("keep-open", "yes")
        _ = mpv_request_log_messages(created, "info")
        let status = mpv_initialize(created)
        guard status >= 0 else {
            mpv_terminate_destroy(created)
            handle = nil
            throw Failure.initialize(status)
        }
    }

    deinit {
        // ⚠️ 顺序：render context **挂在句柄上**，必须在 `mpv_terminate_destroy` 之前放掉，
        // 否则它会在一个已经销毁的句柄上做 free（野指针）。先置 nil 就是"先放它"。
        session = nil
        if let handle { mpv_terminate_destroy(handle) }
    }

    /// 创建渲染上下文。**`MPV_RENDER_API_TYPE_SW` 就是"软件后端"这个事实的来源** ——
    /// 不是从字符串里猜的，是这一行真的被 mpv 接受了。
    public func createRenderContext() throws {
        guard let handle, session == nil else { return }
        session = try MPVSWSession(handle: handle)
    }

    public func load(_ url: URL) {
        guard let handle else { return }
        // ⚠️ 必须**嵌套** `withCString`：早先写成
        //   `["loadfile".withCString { $0 }, path, nil]`
        // 拿到的指针在闭包返回时就失效了（悬空指针，还可能看着"不报错"）——
        // 现象是 `loadfile` 静默失败、`path` 属性始终为 nil。
        let status: Int32 = "loadfile".withCString { command in
            url.absoluteString.withCString { path in
                var args: [UnsafePointer<CChar>?] = [command, path, nil]
                return mpv_command(handle, &args)
            }
        }
        if status < 0 {
            log?("[probe] loadfile 被拒 status=\(status) \(String(cString: mpv_error_string(status)))")
        }
    }

    /// 把 mpv 的事件队列抽干，顺手把它的日志打出来。
    ///
    /// 不抽就会积压 —— 而积压时**播放仍然会走**，所以"没抽事件"平时看不出来，
    /// 只在排查时变成一个假线索。这里显式抽干，就是为了让日志是真的。
    public func pump() {
        guard let handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { return }
            if event.pointee.event_id == MPV_EVENT_NONE { return }
            if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE,
               let raw = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                let prefix = raw.pointee.prefix.map { String(cString: $0) } ?? "?"
                let text = raw.pointee.text.map { String(cString: $0) } ?? ""
                log?("[mpv/\(prefix)] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// 在给定时长内反复渲染，取**非黑占比最高**的那一帧落盘（最多 8 秒）。
    ///
    /// 为什么不"第一帧非黑就返回"：片头常有淡入 / 黑场，第一帧虽然"不是纯黑"，
    /// 但作为证据看不出内容 —— 拿一张几乎全黑的图证明"能取帧"，等于自己给自己降标准。
    /// 判据仍然是"非黑占比"，只是取**窗口内最好的一帧**。
    public func captureFrame(
        width: Int = 640, height: Int = 360, seconds: Double = 6, pngURL: URL? = nil
    ) throws -> Result {
        guard let handle, let session else { throw Failure.renderContext(-1) }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        var bestBuffer = buffer
        var best: Double = 0
        var renders = 0
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            pump()
            _ = session.update()
            let status: Int32 = buffer.withUnsafeMutableBytes { raw in
                session.render(
                    into: raw.baseAddress!, width: width, height: height, stride: bytesPerRow, format: "rgba"
                )
            }
            if status < 0 { throw Failure.render(status) }
            renders += 1

            let ratio = Self.nonBlackRatio(buffer)
            if ratio > best {
                best = ratio
                bestBuffer = buffer
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        _ = handle
        guard best > 0.02 else { throw Failure.noFrame }
        let path = try pngURL.map {
            try Self.writePNG(bestBuffer, width: width, height: height, bytesPerRow: bytesPerRow, to: $0)
        }
        return Result(width: width, height: height, renders: renders, bestNonBlackRatio: best, pngPath: path)
    }

    // MARK: - 私有

    /// mpv 自己怎么看当前状态 —— 取不到帧时**先问它**，别猜。
    ///
    /// 几个属性各有分工：`vo-configured` 说"视频输出建起来没有"、
    /// `video-format` / `width` 说"解出画面没有"、`duration` 说"文件读了没有"。
    public func diagnostics() -> String {
        guard let handle else { return "handle=nil" }
        func string(_ name: String) -> String {
            guard let raw = mpv_get_property_string(handle, name) else { return "nil" }
            defer { mpv_free(raw) }
            return String(cString: raw)
        }
        return [
            "vo-configured=\(string("vo-configured"))",
            "video-format=\(string("video-format"))",
            "width=\(string("width"))",
            "height=\(string("height"))",
            "duration=\(string("duration"))",
            "core-idle=\(string("core-idle"))",
            "pause=\(string("pause"))",
            "path=\(string("path"))"
        ].joined(separator: " ")
    }

    private func option(_ name: String, _ value: String) throws {
        guard let handle else { return }
        let status = name.withCString { key in
            value.withCString { val in
                mpv_set_option_string(handle, key, val)
            }
        }
        guard status >= 0 else { throw Failure.setOption(name, status) }
    }

    /// 判据用"非黑像素占比"，不用"平均亮度"：
    /// 黑场片头、暗色调片子的平均值都会很低，**但它们是画面**；
    /// 而没起播时是**逐像素纯黑**。两者用"有多少像素不是纯黑"才分得开。
    private static func nonBlackRatio(_ buffer: [UInt8]) -> Double {
        var nonBlack = 0
        var index = 0
        while index + 3 < buffer.count {
            if buffer[index] > 8 || buffer[index + 1] > 8 || buffer[index + 2] > 8 {
                nonBlack += 1
            }
            index += 4
        }
        let total = buffer.count / 4
        return total == 0 ? 0 : Double(nonBlack) / Double(total)
    }

    private static func writePNG(
        _ buffer: [UInt8], width: Int, height: Int, bytesPerRow: Int, to url: URL
    ) throws -> String {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var data = buffer
        let status = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = ctx.makeImage(),
                let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest)
        }
        guard status else { throw Failure.noFrame }
        return url.path
    }
}
#endif
