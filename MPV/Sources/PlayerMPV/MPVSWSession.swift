#if os(iOS)
import CoreVideo
import Foundation
import Libmpv

/// mpv 句柄的**可跨 actor 传递**包装。
///
/// `OpaquePointer` 不是 `Sendable`（它就是一串裸地址），而"把内核的句柄交给主线程去建渲染上下文"
/// 这件事本身是安全的 —— 句柄的生命周期由内核（`MPVHandleOwner`）持有，
/// 我们只是**借**它一段时间。用这个显式包装把"我知道我在做什么"写在类型上，
/// 而不是在闭包里用 `@unchecked` 悄悄绕过检查。
public struct MPVHandleBox: @unchecked Sendable {
    public let pointer: OpaquePointer

    public init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }
}

/// **软件后端渲染会话**：把「一个已经存在的 mpv 句柄」变成「能出帧的渲染上下文」。
///
/// 为什么不叫 probe / output：这两件事（取帧落盘、帧上屏）**只差最后一步**，
/// 前面那些（建 `mpv_render_context`、问尺寸、把像素写进一块内存）**完全一样**。
/// 各自写一遍的结果是两份都漂过一点的实现，而"漂过一点"在渲染上等于花屏。
///
/// ⚠️ **线程纪律**：`mpv_render_context_*` 只能从**同一个线程**调用。
/// 谁调 `init` 就在谁那个线程用 —— 本项目里那永远是主线程（`MPVRenderOutput.attach`）。
public final class MPVSWSession {
    public enum Failure: Error, CustomStringConvertible {
        case create(Int32)

        public var description: String {
            switch self {
            case .create(let code): return "mpv_render_context_create：\(code)"
            }
        }
    }

    private let handle: OpaquePointer
    private let context: OpaquePointer
    private var updateSink: UpdateSink?

    /// 更新回调的可持有载体 —— `mpv_render_context_set_update_callback` 只收一个 `void *`，
    /// 而回调**从 mpv 的渲染线程打进来**。把闭包直接塞进未持有的指针，
    /// 会话一销毁就会打到野指针上（同 `MPVHandleOwner` 的 `WakeupSink`，`docs/09` §三 缺陷 c）。
    private final class UpdateSink: @unchecked Sendable {
        let body: @Sendable () -> Void

        init(body: @escaping @Sendable () -> Void) {
            self.body = body
        }
    }

    public init(handle: OpaquePointer) throws {
        var created: OpaquePointer?
        // `MPV_RENDER_API_TYPE_SW` 就是"软件后端"这件事**唯一**的事实来源：
        // 不是从字符串里猜的，是这一行真的被 mpv 接受了（返回 0）。
        let status: Int32 = "sw".withCString { apiType in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return mpv_render_context_create(&created, handle, &params)
        }
        guard status >= 0, let created else { throw Failure.create(status) }
        self.handle = handle
        context = created
    }

    deinit {
        // 顺序：先摘回调（此后 mpv 不再发起新的唤醒），再释放上下文（它会 join 渲染线程）。
        // 反过来的话，可能有一个回调在 `free` 期间打到已经释放的 sink 上。
        mpv_render_context_set_update_callback(context, nil, nil)
        mpv_render_context_free(context)
    }

    /// 有新帧时被调用（**来自 mpv 的线程**）—— 实现里只该置个标记，别在这里渲染。
    public func setUpdates(_ body: @escaping @Sendable () -> Void) {
        let sink = UpdateSink(body: body)
        updateSink = sink
        mpv_render_context_set_update_callback(context, { context in
            guard let context else { return }
            Unmanaged<UpdateSink>.fromOpaque(context).takeUnretainedValue().body()
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    /// 问 mpv「现在要不要重画」。返回值的 `MPV_RENDER_UPDATE_FRAME` 位表示有新帧。
    public func update() -> UInt64 {
        mpv_render_context_update(context)
    }

    /// 把当前帧渲进给定内存。`format` 用 `"bgra"` 与 `CVPixelBuffer` 的 32BGRA 对齐 ——
    /// 这样 mpv 可以**直接写进 IOSurface**，我们不必再从中间数组拷一遍。
    public func render(
        into base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int, format: String = "bgra"
    ) -> Int32 {
        var size: [Int32] = [Int32(width), Int32(height)]
        var rowStride = stride
        return format.withCString { name in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: &size),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: name)),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: &rowStride),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return mpv_render_context_render(context, &params)
        }
    }

    /// 当前该按多大渲染。
    ///
    /// 用 `dwidth`/`dheight` 而**不是** `width`/`height`：后者是**编码**尺寸，
    /// 前者是**显示**尺寸（已含 SAR / 旋转）。两者在绝大多数片子上相同，
    /// 差别只在"变形宽银幕 / 竖拍带旋转标记"这类素材上 —— 而那正是会露出错误的地方。
    public func videoSize() -> (width: Int, height: Int)? {
        guard let width = int64("dwidth"), let height = int64("dheight"),
              width > 0, height > 0
        else { return nil }
        return (Int(width), Int(height))
    }

    private func int64(_ name: String) -> Int64? {
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }
}
#endif
