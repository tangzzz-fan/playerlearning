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
    /// 最近一次加载的资源。
    ///
    /// 存在的唯一理由是 `play()`：mpv 的 `stop` 会清空播放列表，
    /// 想"停止后再播"就必须把文件**重新放回去**（见 `play()` 的说明）。
    private var lastResource: PlayerResource?
    private var continuation: AsyncStream<PlayerKernelEvent>.Continuation?
    private var state: PlayerState = .idle
    private var currentTime: Double = 0
    private var duration: Double = 0
    private var isBuffering = false
    private var naturalSize: CGSize = .zero
    private var videoSizeTracker = VideoSizeTracker()
    private var audio = PlayerAudioState()
    private var subtitles = PlayerSubtitleState()

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
            naturalSize: naturalSize,
            audio: audio,
            subtitles: subtitles
        )
    }

    public func load(_ resource: PlayerResource) async throws {
        let handle = try prepare()
        lastResource = resource
        emit(.stateChanged(.preparing))
        try send(handle, ["loadfile", resource.url.absoluteString, "replace"])
    }

    /// 开始播放。
    ///
    /// ⚠️ **不是简单地置 `pause=no`** —— 那在两种常见情形下什么都不做：
    ///
    /// ① **「停止」之后**：mpv 的 `stop` 命令会**清空播放列表**，此后没有文件可播，
    ///    `pause=no` 不会让任何东西动起来。「停止 → 播放」在播放器语义里就是
    ///    **「从头再播一次」**，所以必须把上一个文件重新放回去。
    /// ② **播完之后**（`keep-open=yes` 停在末帧）：只置 `pause=no` 会在原地**立刻再次 EOF**，
    ///    表现是"按了播放但画面不动"。这时要**先回开头**。
    ///
    /// 两条都是实测出来的（见 `MPVKernelTests` 里对应的两条用例）——
    /// 它们共同的症状是**「点了没反应」**，而代码看上去完全正确。
    public func play() async {
        guard let handle = owner?.pointer else { return }

        if isPlaylistEmpty(handle) {
            guard let lastResource else { return }
            // 重载之前先把 `pause` 放开：它是个**全局属性**，`loadfile` 之后会保持原值，
            // 若停止时恰好是暂停态，重载出来的新播放会一动不动。
            setProperty(handle, "pause", "no")
            emit(.stateChanged(.preparing))
            try? send(handle, ["loadfile", lastResource.url.absoluteString, "replace"])
            return
        }

        if state == .finished {
            // 回开头再放开暂停。`seek` 之后 `eof-reached` 会自动回到 false，
            // 而那条属性只在"变真"时上报，所以这一步不会多报状态。
            try? send(handle, ["seek", "0", "absolute+exact"])
        }
        setProperty(handle, "pause", "no")
        // 命令之后**主动回读**，不坐等"变化"通知：同值不通知（`P-038` 同源）。
        emitPauseState()
    }

    /// 理由同 `play()`。
    public func pause() async {
        guard let handle = owner?.pointer else { return }
        setProperty(handle, "pause", "yes")
        emitPauseState()
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

    /// 加一条外挂字幕。
    ///
    /// ⚠️ 发完命令**立刻自己读一次轨道清单**，而不是坐等 `track-list` 的"变化"通知 ——
    /// 这是 `P-038` 的教训：**「问现在是什么」比「等它通知我变了」可靠**。
    /// （`track-list/count` 是否可被 observe 是**要验证的假设**，不能把它当既成事实。）
    public func addSubtitle(url: URL, title: String?) async {
        guard let handle = owner?.pointer else { return }
        var arguments = ["sub-add", url.absoluteString, "select"]
        if let title, !title.isEmpty { arguments.append(title) }
        try? send(handle, arguments)
        refreshSubtitleState()
    }

    /// 选中某条字幕轨；`nil` = `sid=no`（不显示任何字幕轨）。
    public func selectSubtitleTrack(id: Int64?) async {
        guard let handle = owner?.pointer else { return }
        setProperty(handle, "sid", id.map(String.init) ?? "no")
        refreshSubtitleState()
    }

    /// `sub-visibility` —— 只发命令，状态由回读/观察得到（同 `P2-T5` 对 `pause` 的做法）。
    public func setSubtitleVisible(_ visible: Bool) async {
        guard let handle = owner?.pointer else { return }
        setProperty(handle, "sub-visibility", visible ? "yes" : "no")
        refreshSubtitleState()
    }

    /// `sub-delay`，正数 = 字幕晚出现。**钳制不在内核做**（由装配层 `PlayerController` 履行）。
    public func setSubtitleDelay(_ seconds: Double) async {
        guard let handle = owner?.pointer else { return }
        setProperty(handle, "sub-delay", String(seconds))
        refreshSubtitleState()
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
        // 音频链路：**解码端**与**输出端**分开观察 ——
        // "有音轨在解码"（audio-params）与"音频输出已建立"（audio-out-params）是两件事，
        // 只有后者才意味着声音真的进了输出设备。`G2` 的"出声"一项就靠它拿证据。
        _ = mpv_observe_property(handle, 0, "audio-params/samplerate", MPV_FORMAT_INT64)
        _ = mpv_observe_property(handle, 0, "audio-out-params/samplerate", MPV_FORMAT_INT64)
        // 字幕：轨道清单的变化（`track-list/count`）+ 三个状态属性。
        // ⚠️ `track-list/count` 能否被 observe 需实测；我们**没有**把正确性押在它上面 ——
        //    每次命令之后与 `FILE_LOADED` 之后都会主动回读（见 `refreshSubtitleState`）。
        _ = mpv_observe_property(handle, 0, "track-list/count", MPV_FORMAT_INT64)
        _ = mpv_observe_property(handle, 0, "sid", MPV_FORMAT_INT64)
        _ = mpv_observe_property(handle, 0, "sub-visibility", MPV_FORMAT_FLAG)
        _ = mpv_observe_property(handle, 0, "sub-delay", MPV_FORMAT_DOUBLE)
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
            // 换文件会重建轨道清单（内挂字幕就在这一步出现）⇒ 必须回读，
            // 否则界面上的字幕菜单永远停在上一个文件的轨道上。
            refreshSubtitleState()
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
    ///
    /// ⚠️ **先确认"有文件在播"再解读 `pause`**（见 `isPlaylistEmpty`）——
    /// 判据不是"pause 等于什么"，而是"有没有东西可以被 pause"。
    private func emitPauseState() {
        guard let handle = owner?.pointer else { return }
        guard !isPlaylistEmpty(handle) else { return }
        var flag: Int32 = 0
        guard mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &flag) >= 0 else { return }
        emit(.stateChanged(flag != 0 ? .paused : .playing))
    }

    /// 播放列表是否为空。
    ///
    /// **`pause=no` 不等于「正在播放」**：`stop` 之后播放列表为空，
    /// 而 mpv 此时的 `pause` 同样是 `no`。少这一层判断的后果很具体 ——
    /// "停止后按暂停"会把内核状态读成 `.playing`，而它其实什么都没在播。
    private func isPlaylistEmpty(_ handle: OpaquePointer) -> Bool {
        (getInt64(handle, "playlist-count") ?? 0) == 0
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
            // 同 `emitPauseState()`：**先确认有文件在播**再解读这条属性。
            // 没有这一层，"停止后 mpv 把 pause 重置为 no"会被读成"开始播放了"。
            guard let handle = owner?.pointer, !isPlaylistEmpty(handle) else { return }
            emit(.stateChanged(UnsafePointer<Int32>(OpaquePointer(data)).pointee != 0 ? .paused : .playing))
        case "audio-params/samplerate":
            let rate = Int(UnsafePointer<Int64>(OpaquePointer(data)).pointee)
            if let next = audio.setDecoderSampleRate(rate) {
                emit(.audioChanged(next))
            }
        case "audio-out-params/samplerate":
            let rate = Int(UnsafePointer<Int64>(OpaquePointer(data)).pointee)
            if let next = audio.setOutputSampleRate(rate) {
                emit(.audioChanged(next))
            }
        case "eof-reached":
            // 只在**变真**时上报：回复到 false（用户 seek 回去继续看）由 `pause` 那条边负责表达，
            // 这里不再多报一个状态，避免"退回去继续播"变成两次状态翻转。
            guard UnsafePointer<Int32>(OpaquePointer(data)).pointee != 0 else { return }
            emit(.stateChanged(.finished))
        case "track-list/count", "sid", "sub-visibility", "sub-delay":
            // 四条都走同一个"回读整份字幕状态"的路径：它们互相影响
            // （比如 `sid` 变了，`track-list/N/selected` 也变了），逐条拼状态容易拼出不一致的中间态。
            refreshSubtitleState()
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
        case .audioChanged(let state):
            audio = state
        case .subtitlesChanged(let state):
            subtitles = state
        }
    }

    // MARK: - 字幕状态回读

    /// 从内核**回读整份字幕状态**，有变化才上报。
    ///
    /// 为什么不逐属性拼：`sid` / `sub-visibility` / `sub-delay` / 轨道清单互相影响，
    /// 逐条更新会在两者之间产生"界面看得到但内核不认"的中间态。
    /// 一次读全、一次比较、一次上报，是这里唯一不容易出错的做法。
    private func refreshSubtitleState() {
        guard let handle = owner?.pointer else { return }
        let next = PlayerSubtitleState(
            tracks: readSubtitleTracks(handle),
            selectedTrackID: readSelectedSubtitleTrackID(handle),
            isVisible: getFlag(handle, "sub-visibility") ?? subtitles.isVisible,
            delay: SubtitleTimeline.normalizeDelay(getDouble(handle, "sub-delay") ?? subtitles.delay)
        )
        guard next != subtitles else { return }
        subtitles = next
        emit(.subtitlesChanged(next))
    }

    private func readSubtitleTracks(_ handle: OpaquePointer) -> [SubtitleTrack] {
        guard let count = getInt64(handle, "track-list/count"), count > 0 else { return [] }
        var tracks: [SubtitleTrack] = []
        for index in 0..<Int(count) {
            let prefix = "track-list/\(index)"
            guard let type = getString(handle, "\(prefix)/type"), type == "sub" else { continue }
            let codec = getString(handle, "\(prefix)/codec")
            tracks.append(
                SubtitleTrack(
                    id: getInt64(handle, "\(prefix)/id") ?? -1,
                    title: getString(handle, "\(prefix)/title"),
                    language: getString(handle, "\(prefix)/lang"),
                    isExternal: getFlag(handle, "\(prefix)/external") ?? false,
                    // 容器里的内挂字幕常常只报一个通用 `sub`，那不是编解码信息 ⇒ 置空。
                    codec: codec == "sub" ? nil : codec
                )
            )
        }
        return tracks
    }

    /// mpv 用**负值**表示"没有选中"（`sid=no`）—— 这里把它归一成 `nil`，
    /// 让上层只需要处理一种"没有"的表示法。
    private func readSelectedSubtitleTrackID(_ handle: OpaquePointer) -> Int64? {
        guard let sid = getInt64(handle, "sid"), sid >= 0 else { return nil }
        return sid
    }

    private func getString(_ handle: OpaquePointer, _ name: String) -> String? {
        var value: UnsafeMutablePointer<CChar>?
        guard mpv_get_property(handle, name, MPV_FORMAT_STRING, &value) >= 0, let value else { return nil }
        defer { mpv_free(value) }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    private func getInt64(_ handle: OpaquePointer, _ name: String) -> Int64? {
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    private func getDouble(_ handle: OpaquePointer, _ name: String) -> Double? {
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    private func getFlag(_ handle: OpaquePointer, _ name: String) -> Bool? {
        var value: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value != 0
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
