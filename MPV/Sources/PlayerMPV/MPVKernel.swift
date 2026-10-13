#if canImport(Libmpv)
import CoreGraphics
import Foundation
import Libmpv
import PlayerCore

public enum MPVKernelError: Error, Equatable, Sendable {
    case creationFailed
    case initializationFailed(code: Int32)
    case commandFailed(name: String, code: Int32)
}

/// mpv 唤醒回调的**可安全持有**的触发器。
///
/// `mpv_set_wakeup_callback` 只接受一个 `void *` 上下文，而回调**可能从 mpv 自己的线程打进来**。
/// 原先直接把 `self` 的**未持有**指针塞进去（`passUnretained`）⇒ kernel 一开始释放，
/// 回调仍可能拿到已失效的指针（`docs/09` §三 缺陷 c）。
///
/// 现在：`sink` 由 `MPVHandleOwner` **强持有**（`passRetained`），
/// 且**在 `mpv_terminate_destroy` 返回之后**才释放 —— 那时 mpv 的线程已经 join，不再有回调在飞。
/// `sink` 自身**不强持有** kernel（闭包里 `[weak self]`），所以**不会**形成
/// `kernel → owner → sink → kernel` 的引用环（否则 kernel 永远释放不掉，等于另一种泄漏）。
private final class WakeupSink: @unchecked Sendable {
    private let notify: @Sendable () -> Void

    init(notify: @escaping @Sendable () -> Void) {
        self.notify = notify
    }

    func fire() {
        notify()
    }
}

private final class MPVHandleOwner: @unchecked Sendable {
    let pointer: OpaquePointer
    private let sink: Unmanaged<WakeupSink>

    init(pointer: OpaquePointer, sink: WakeupSink) {
        self.pointer = pointer
        self.sink = Unmanaged.passRetained(sink)
    }

    deinit {
        // 顺序有讲究：先摘回调（此后 mpv 不再发起新的唤醒），
        // 再销毁句柄（join mpv 线程，确保没有回调正在执行），最后才放掉 sink。
        mpv_set_wakeup_callback(pointer, nil, nil)
        mpv_terminate_destroy(pointer)
        sink.release()
    }
}

public actor MPVKernel: PlayerKernelProtocol {
    private var owner: MPVHandleOwner?
    private let windowEmbedHandle: Int64?
    private var continuation: AsyncStream<PlayerKernelEvent>.Continuation?
    private var state: PlayerState = .idle
    private var currentTime: Double = 0
    private var duration: Double = 0
    private var isBuffering = false
    private var naturalSize: CGSize = .zero
    private var videoSizeTracker = VideoSizeTracker()

    /// 注册表用的**无参**构造（`PlayerKernelProtocol` 要求）—— 等价于**无画面**。
    ///
    /// ⚠️ **不要把这条路径当作"默认构造"**：它给不出画面，`vo` 会落到 `null`。
    /// 需要画面时必须用 `init(windowEmbedHandle:)` 显式给出宿主句柄。
    ///
    /// 为什么保留而不是删掉：`PlayerKernelRegistry` 靠无参构造才能泛型地实例化内核类型。
    /// 但这条口子有个已知隐患 —— 当内核分派真正投入使用（第二个内核出现）时，
    /// 无参构造口**必须**换成携带视频表面的构造口，否则"注册表造出来的播放器没有画面"
    /// 会以**零报错**的形式重现（就是本票修掉的缺陷 a 的变体）。已记入 `docs/03`。
    public init() {
        windowEmbedHandle = nil
    }

    /// 有画面的构造：`windowEmbedHandle` 是宿主原生窗口句柄（iOS 上是 `UIView` 的 `wid`）。
    ///
    /// **必须在构造时给定**：`applyOptions` 在 `mpv_initialize` **之前**读它，
    /// 原先那个 `attach` setter 会让"晚一步"变成**静默无画面**（`docs/09` §三 缺陷 a）。
    /// 参数**非可选**是刻意的 —— 想要无画面请走 `init()`，那是显式选择而非时序事故。
    public init(windowEmbedHandle: Int64) {
        self.windowEmbedHandle = windowEmbedHandle
    }

    public func events() async -> AsyncStream<PlayerKernelEvent> {
        let (stream, continuation) = AsyncStream<PlayerKernelEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func snapshot() async -> PlayerKernelSnapshot {
        PlayerKernelSnapshot(
            state: state,
            currentTime: currentTime,
            duration: duration,
            isBuffering: isBuffering,
            naturalSize: naturalSize
        )
    }

    public func load(_ resource: PlayerResource) async throws {
        let handle = try prepare()
        emit(.stateChanged(.preparing))
        try send(handle, ["loadfile", resource.url.absoluteString, "replace"])
    }

    /// **不在这里上报状态。** `pause` 是 mpv 的**权威可观测属性**，状态一律由 `applyProperty` 观察得到
    /// ⇒ 命令只负责"发出请求"，状态由内核回执。这样 mpv 内部产生的暂停（缓存 / EOF / `keep-open`）也不会漏。
    /// 对照：`load()` 的 `.preparing` 与 `stop()` 的 `.idle` **没有**对应的可观测属性，才保留乐观上报。
    public func play() async {
        guard let handle = owner?.pointer else { return }
        setProperty(handle, "pause", "no")
    }

    /// 理由同 `play()`。
    public func pause() async {
        guard let handle = owner?.pointer else { return }
        setProperty(handle, "pause", "yes")
    }

    public func stop() async {
        guard let handle = owner?.pointer else { return }
        try? send(handle, ["stop"])
        emit(.stateChanged(.idle))
    }

    /// 精确 seek（`absolute+exact`）。
    ///
    /// 默认的 `absolute` 只 seek 到**最近的关键帧**，落点会往前偏几十到几百毫秒 ——
    /// 拖进度条时表现为"松手回弹"。`exact` 让 mpv 精确解码到目标帧位置。
    /// **钳制不在这里做**：目标值的合法区间属于模型知识，由装配层 `PlayerController`
    /// 经 `PlayerTimeModel.clampSeekTarget` 履行（内核只管执行）。
    public func seek(to seconds: Double) async {
        guard let handle = owner?.pointer else { return }
        try? send(handle, ["seek", String(seconds), "absolute+exact"])
    }

    public func finishEvents() {
        continuation?.finish()
        continuation = nil
    }

    public func shutdown() {
        finishEvents()
        owner = nil
    }

    private func prepare() throws -> OpaquePointer {
        if let handle = owner?.pointer {
            return handle
        }
        guard let created = mpv_create() else {
            emit(.stateChanged(.failed))
            throw MPVKernelError.creationFailed
        }
        do {
            applyOptions(created)
            observeProperties(created)
            let status = mpv_initialize(created)
            guard status >= 0 else {
                throw MPVKernelError.initializationFailed(code: status)
            }
        } catch {
            mpv_terminate_destroy(created)
            emit(.stateChanged(.failed))
            throw error
        }
        let sink = WakeupSink { [weak self] in
            Task { await self?.drainEvents() }
        }
        let handleOwner = MPVHandleOwner(pointer: created, sink: sink)
        owner = handleOwner
        installWakeupCallback(created, sink: sink)
        return created
    }

    private func applyOptions(_ handle: OpaquePointer) {
        if let windowEmbedHandle {
            var embedHandle = windowEmbedHandle
            _ = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &embedHandle)
            setOption(handle, "vo", "gpu-next")
            setOption(handle, "gpu-api", "vulkan")
            setOption(handle, "gpu-context", "moltenvk")
            setOption(handle, "hwdec", "videotoolbox")
        } else {
            setOption(handle, "vo", "null")
            setOption(handle, "hwdec", "no")
        }
        setOption(handle, "keep-open", "yes")
        setOption(handle, "idle", "yes")
        setOption(handle, "terminal", "no")
        setOption(handle, "osc", "no")
    }

    private func observeProperties(_ handle: OpaquePointer) {
        _ = mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        // `pause` 是播放/暂停状态的权威来源（`play()`/`pause()` 不再乐观上报）。
        _ = mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        // `width`/`height` 是两个**独立**属性、回调时机不保证成对 ⇒ 交给 VideoSizeTracker 合成。
        _ = mpv_observe_property(handle, 0, "width", MPV_FORMAT_INT64)
        _ = mpv_observe_property(handle, 0, "height", MPV_FORMAT_INT64)
        // ⚠️ 播到结尾的**唯一可靠信号**：我们开着 `keep-open=yes`，
        //    此时 mpv 到 EOF 只会把 `pause` 置 yes 并停住末帧，**不发 `MPV_EVENT_END_FILE`**
        //    （实测：播完 15 秒内一条 `.finished` 都没有）⇒ `.finished` 会变成不可达状态。
        //    mpv 的文档也点明 `eof-reached` 只在用 `--keep-open` 时才有意义 —— 两者正好配对。
        _ = mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)
    }

    private nonisolated func installWakeupCallback(_ handle: OpaquePointer, sink: WakeupSink) {
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<WakeupSink>.fromOpaque(context).takeUnretainedValue().fire()
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    private func drainEvents() {
        guard let handle = owner?.pointer else { return }
        while let event = mpv_wait_event(handle, 0) {
            let identifier = event.pointee.event_id
            if identifier == MPV_EVENT_NONE {
                break
            }
            handleEvent(event.pointee)
            if identifier == MPV_EVENT_SHUTDOWN {
                break
            }
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            emit(.stateChanged(.readyToPlay))
            emitPauseState()
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            emitEndFile(UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            applyProperty(UnsafePointer<mpv_event_property>(OpaquePointer(data)).pointee)
        default:
            break
        }
    }

    /// `FILE_LOADED` 之后**主动读一次** `pause`，而不是等它的"变化"通知。
    ///
    /// 为什么必须主动读（实测踩到）：换文件时 `pause` 的值**没有变化**（前后都是 `no`），
    /// mpv 于是**不发** `MPV_EVENT_PROPERTY_CHANGE` ⇒ 新文件明明在放，
    /// 状态却永久停在 `.readyToPlay`（事件流里 `currentTimeChanged` 一路推进，状态不动）。
    /// 只依赖"变化"通知，等于把"当前值"这件事交给了一个只报告差异的信号。
    private func emitPauseState() {
        guard let handle = owner?.pointer else { return }
        var flag: Int32 = 0
        guard mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &flag) >= 0 else { return }
        emit(.stateChanged(flag != 0 ? .paused : .playing))
    }

    /// **必须按 `reason` 分派。** 无条件报 `.finished` 会让坏文件永远进不了 `.failed` ——
    /// `PlayerState.failed` 于是成为死代码，UI 无从区分「放完了」和「放失败了」。
    /// 注意 `MPV_END_FILE_REASON_EOF` **不是**成功信号：不完整的文件与断掉的网络流也可能报它。
    private func emitEndFile(_ endFile: mpv_event_end_file) {
        guard let reason = PlaybackEndReason(mpvReason: endFile.reason),
              let newState = reason.resultingState
        else { return }
        emit(.stateChanged(newState))
    }

    private func applyProperty(_ property: mpv_event_property) {
        guard let data = property.data else { return }
        switch String(cString: property.name) {
        case "time-pos":
            emit(.currentTimeChanged(UnsafePointer<Double>(OpaquePointer(data)).pointee))
        case "duration":
            emit(.durationChanged(UnsafePointer<Double>(OpaquePointer(data)).pointee))
        case "paused-for-cache":
            emit(.bufferingChanged(UnsafePointer<Int32>(OpaquePointer(data)).pointee != 0))
        case "pause":
            emit(.stateChanged(UnsafePointer<Int32>(OpaquePointer(data)).pointee != 0 ? .paused : .playing))
        case "eof-reached":
            // 只在**变真**时上报：回复到 false（用户 seek 回去继续看）由 `pause` 那条边负责表达，
            // 这里不再多报一个状态，避免"退回去继续播"变成两次状态翻转。
            guard UnsafePointer<Int32>(OpaquePointer(data)).pointee != 0 else { return }
            emit(.stateChanged(.finished))
        case "width":
            let width = Int(UnsafePointer<Int64>(OpaquePointer(data)).pointee)
            if let size = videoSizeTracker.setWidth(width) {
                emit(.videoSizeChanged(size))
            }
        case "height":
            let height = Int(UnsafePointer<Int64>(OpaquePointer(data)).pointee)
            if let size = videoSizeTracker.setHeight(height) {
                emit(.videoSizeChanged(size))
            }
        default:
            break
        }
    }

    private func emit(_ event: PlayerKernelEvent) {
        apply(event)
        _ = continuation?.yield(event)
    }

    private func apply(_ event: PlayerKernelEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
        case .currentTimeChanged(let seconds):
            currentTime = seconds
        case .durationChanged(let seconds):
            duration = seconds
        case .bufferingChanged(let flag):
            isBuffering = flag
        case .videoSizeChanged(let size):
            naturalSize = size
        }
    }

    private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
        _ = mpv_set_option_string(handle, name, value)
    }

    private func setProperty(_ handle: OpaquePointer, _ name: String, _ value: String) {
        _ = mpv_set_property_string(handle, name, value)
    }

    private func send(_ handle: OpaquePointer, _ arguments: [String]) throws {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { argument in
            strdup(argument).map { UnsafePointer<CChar>($0) }
        }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                if let pointer {
                    free(UnsafeMutablePointer(mutating: pointer))
                }
            }
        }
        let status = mpv_command(handle, &pointers)
        guard status >= 0 else {
            throw MPVKernelError.commandFailed(name: arguments.first ?? "", code: status)
        }
    }
}
#endif
