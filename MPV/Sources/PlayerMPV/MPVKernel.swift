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

private final class MPVHandleOwner: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        mpv_set_wakeup_callback(pointer, nil, nil)
        mpv_terminate_destroy(pointer)
    }
}

public actor MPVKernel: PlayerKernelProtocol {
    private var owner: MPVHandleOwner?
    private var windowEmbedHandle: Int64?
    private var continuation: AsyncStream<PlayerKernelEvent>.Continuation?
    private var state: PlayerState = .idle
    private var currentTime: Double = 0
    private var duration: Double = 0
    private var isBuffering = false
    private var naturalSize: CGSize = .zero
    private var videoSizeTracker = VideoSizeTracker()

    public init() {}

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

    public func seek(to seconds: Double) async {
        guard let handle = owner?.pointer else { return }
        try? send(handle, ["seek", String(seconds), "absolute"])
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
        owner = MPVHandleOwner(pointer: created)
        installWakeupCallback(created)
        return created
    }

    public func attach(windowEmbedHandle: Int64) {
        self.windowEmbedHandle = windowEmbedHandle
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
    }

    private nonisolated func installWakeupCallback(_ handle: OpaquePointer) {
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let kernel = Unmanaged<MPVKernel>.fromOpaque(context).takeUnretainedValue()
            Task { await kernel.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
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
