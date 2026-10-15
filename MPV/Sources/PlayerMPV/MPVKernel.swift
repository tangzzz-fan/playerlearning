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
    private var videoTracks = PlayerVideoTrackState()
    /// 被 mpv 拒绝的选项（名字拼错 / 版本不支持）。**空数组才是正常状态**。
    private var rejectedOptions: [String] = []
    /// 内核日志出口（见 `enableLogging`）。
    private var logHandler: (@Sendable (String) -> Void)?
    /// 期望的日志级别。句柄可能还没建（首次 `load` 才建），所以先记住，`prepare()` 时补上。
    private var requestedLogLevel: String?

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
            subtitles: subtitles,
            videoTracks: videoTracks
        )
    }

    public func load(_ resource: PlayerResource) async throws {
        let handle = try prepare(resource)
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

        // 停在片尾再点「播放」= **从头再播一次**。
        //
        // ⚠️ 判据去问 mpv（`eof-reached`），**不能**看本地 `state`：
        //    本地那一份是"最后一次上报"的副本，不是权威 —— `P-038` 的判据
        //    「**问现在是什么，别信本地记的那一份**」在这里同样适用。
        // 读不到（`nil`）时退回 `state`：不确定不能当成确定（`P-051` 同族）。
        // 停在片尾再点「播放」= **从头再播一次**。
        //
        // ⚠️ 判据去问 mpv（`eof-reached`），**不能**看本地 `state`：
        //    真机实测：EOF 时 mpv 的两条上报**相隔 9 ms**（`pause=yes` 3.215 / `eof-reached=yes` 3.224），
        //    **谁先到没有保证**。本地 `state` 只是"最后一次上报"的副本，不是权威 ——
        //    判据同 `P-038`：**问现在是什么，别信本地记的那一份**。
        //    读不到（`nil`）时退回 `state`：不确定不能当成确定（`P-051` 同族）。
        let atEnd = getFlag(handle, "eof-reached") ?? (state == .finished)
        if atEnd {
            // `.finished` 是**终态**（`docs/03` 记录过那条"刻意保留的拒绝"），
            // 所以"再播一次"必须重新走一遍 `preparing` —— **不能**直接报 `.playing`，
            // 那条边在状态机里是非法迁移（`.finished → .playing`）。
            // 少了这两步的真机症状：画面已经在重播、内核只报了 `.playing`，
            // 而装配层**如实拒收**那条非法边 ⇒ 界面永远停在 `finished`
            // （按钮不换、状态行不改）—— 用户看到的就是「点了没反应」（`-exerciseFinish` 实测）。
            emit(.stateChanged(.preparing))
            try? send(handle, ["seek", "0", "absolute+exact"])
            emit(.stateChanged(.readyToPlay))
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

    /// 选中一条视频轨（`vid`）—— 「可切清晰度」的抓手。
    ///
    /// 与 `sid` 对称，但**没有"关掉"这个分支**：`vid=no` 等于没有画面，
    /// 那不是播放器可以停留的状态（协议里参数也据此写成非可选）。
    /// 发完命令**立刻回读**，理由同 `addSubtitle`（`P-038`：问"现在是什么"比等通知可靠）。
    public func selectVideoTrack(id: Int64) async {
        guard let handle = owner?.pointer else { return }
        setProperty(handle, "vid", String(id))
        refreshVideoTrackState()
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

    private func prepare(_ resource: PlayerResource) throws -> OpaquePointer {
        if let handle = owner?.pointer {
            // 换文件时必须**重设**请求头：mpv 的选项挂在句柄上，
            // 不重设就会把上一个文件的头继续发出去 —— 而且完全不报错。
            applyRequestHeaders(handle, resource)
            return handle
        }
        guard let created = mpv_create() else {
            emit(.stateChanged(.failed))
            throw MPVKernelError.creationFailed
        }
        do {
            applyOptions(created, resource)
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
        // 日志可能是在句柄建立**之前**就要求打开的（`enableLogging` 早于首次 load）。
        if let requestedLogLevel {
            let status = mpv_request_log_messages(created, requestedLogLevel)
            logHandler?("[mpv/request] level=\(requestedLogLevel) handle=created status=\(status)")
        }
        return created
    }

    private func applyOptions(_ handle: OpaquePointer, _ resource: PlayerResource) {
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
        // ⚠️ 这里曾经还有一条 `osc=no` —— 它**从来没生效过**，直到
        // `testEveryConfiguredOptionIsAcceptedByMPV` 把它抓出来：
        // 自建的 LGPL 产物是**精简构建**（不带 OSC / lua），该选项**根本不存在**。
        // 删掉而不是"允许它失败"：**设一个不存在的选项，除了制造"我配过了"的错觉，
        // 没有任何作用。**
        applyNetworkOptions(handle)
        applyRequestHeaders(handle, resource)
    }

    /// 请求头注入（`P5-T4`）。
    ///
    /// 两条取值都**无条件写**，包括"空"：
    /// mpv 的选项是挂在句柄上的，只在"有值"时才写，会让上一个文件的头**留着继续发**，
    /// 而且不报任何错 —— 这正是 `P-047` 那种"旧东西静默挡住新的"。
    ///
    /// ⚠️ 首次加载时这段是在 `mpv_initialize` **之前**跑的（`applyOptions` 里），
    /// 换文件时则是运行期重设 —— 两条路都必须能被 mpv 接受，
    /// 由 `testEveryConfiguredOptionIsAcceptedByMPV` 一类的用例兜底（`rejectedOptions`）。
    private func applyRequestHeaders(_ handle: OpaquePointer, _ resource: PlayerResource) {
        let plan = RequestHeaders(resource.headers)
        setOption(handle, "http-header-fields", plan.headerFields ?? "")
        setOption(handle, "user-agent", plan.userAgent ?? Self.defaultUserAgent)
    }

    /// 没有自定义 UA 时的默认值 —— 不少 CDN 直接按 UA 拒绝，空 UA 是最容易被拒的一种。
    private static let defaultUserAgent = "PlayerStack/1.0"

    /// 网络点播相关的 mpv 选项（`P5-T1` / `P5-T2`）。
    ///
    /// ⚠️ **这几项没有参考实现可抄** —— 实测核实过：`vendor/ksplayer` 的 `MPVHandle`
    /// 完全不碰网络/缓存参数。所以取值依据 mpv 官方文档，
    /// 而"它们到底生效了没有"由 `rejectedOptions` 兜底，
    /// **不能**用"照文档写的所以肯定对"来替代验证。
    ///
    /// 原则：**让 mpv 吸收网络抖动，而不是让 UI 去处理**。
    private func applyNetworkOptions(_ handle: OpaquePointer) {
        // 显式打开缓存。默认的 `auto` 会按流类型自己决定，对本地文件够用，
        // 但网络流的抖动必须由缓存吸收 —— 否则表现为画面一顿一顿。
        setOption(handle, "cache", "yes")
        // 起播前先攒够再开始：网络流最糟的第一印象就是"点开先卡三秒"。
        setOption(handle, "cache-pause-initial", "yes")
        setOption(handle, "cache-pause-wait", "3")
        // 前向 / 后向缓冲上限（字节）。**给上限是为了不让网络流把内存吃光** ——
        // 没有上限时，一个长片的缓存可以轻易吃掉几百 MB。
        setOption(handle, "demuxer-max-bytes", "64MiB")
        setOption(handle, "demuxer-max-back-bytes", "16MiB")
        // 网络超时：太短会在弱网下误判为"流断了"，太长会让"打不开"迟迟不报错。
        setOption(handle, "network-timeout", "30")
        // ⚠️ `user-agent` 不在这里设 —— 它归 `applyRequestHeaders`（UA 必须**单源**，
        //    否则"写死的默认值"与"资源带的 UA"会互相盖，而谁生效没人说得清）。
    }

    /// 供测试断言：**空数组 = 所有配置过的选项 mpv 都认**。
    public func rejectedOptionNames() -> [String] {
        rejectedOptions
    }

    /// 打开 mpv 自己的日志并转发出去（排查用）。
    ///
    /// **为什么必须有这条通道**：网络流为什么没播起来、编码为什么解不开、协议协商为什么失败 ——
    /// 这些问题**从我们的状态机里看不出来**（我们只看到"它说 EOF 了"）。
    /// 内核自己的日志是唯一说得清的地方；没有它就只能靠猜，而猜错的方向代价很高。
    /// ⚠️ **签名必须与协议要求逐字一致**（`enableLogging(_:)`，单参数）。
    /// 我第一版写成 `enableLogging(level:handler:)` —— 带默认参数的方法**不满足**单参数要求，
    /// 于是编译器**静默选中了协议的默认实现（no-op）**，我这个实现从来没被调用过。
    /// 症状是"日志一行都没有"，而它看起来完全像是在正常工作。
    /// **默认实现是个好东西，但它会把"签名写错了"变成"什么都没发生"。**
    public func enableLogging(_ handler: @escaping @Sendable (String) -> Void) async {
        let level = "v"
        logHandler = handler
        requestedLogLevel = level
        // 自报一行：否则"内核一行日志都没有"与"日志通道压根没打开"看起来一模一样
        // —— 而这两种情况的排查方向完全相反。
        let handle = owner?.pointer
        let status = handle.map { mpv_request_log_messages($0, level) } ?? -999
        handler("[mpv/request] level=\(level) handle=\(handle != nil ? "ready" : "pending") status=\(status)")
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
        // 视频轨：`vid` 是当前的档位。轨道清单的变化由上面那条 `track-list/count` 一并覆盖
        // （一个属性驱动两条回读路径，见 `applyProperty`）。
        _ = mpv_observe_property(handle, 0, "vid", MPV_FORMAT_INT64)
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
            // **视频轨同理**：HLS 多码率的档位清单也是在这一步才齐的，
            // 不回读的话「清晰度」菜单会一直空着（而且没有任何报错）。
            refreshSubtitleState()
            refreshVideoTrackState()
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            emitEndFile(UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            applyProperty(UnsafePointer<mpv_event_property>(OpaquePointer(data)).pointee)
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data, let logHandler else { return }
            let message = UnsafePointer<mpv_event_log_message>(OpaquePointer(data)).pointee
            let prefix = String(cString: message.prefix)
            let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            logHandler("[mpv/\(prefix)] \(text)")
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
        guard !isPlaylistEmpty(handle) else {
            logHandler?("[mpv/pause] 跳过：playlist 为空")
            return
        }
        var flag: Int32 = 0
        guard mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &flag) >= 0 else {
            logHandler?("[mpv/pause] 读取 pause 失败")
            return
        }
        emit(.stateChanged(flag != 0 ? .paused : .playing))
    }

    /// 播放列表是否为空。
    ///
    /// **`pause=no` 不等于「正在播放」**：`stop` 之后播放列表为空，
    /// 而 mpv 此时的 `pause` 同样是 `no`。少这一层判断的后果很具体 ——
    /// "停止后按暂停"会把内核状态读成 `.playing`，而它其实什么都没在播。
    ///
    /// ⚠️ **读失败时返回 `false`（= 不阻断）**，不能写成 `?? 0`。
    /// 那个默认值会把"**读不到**"变成"**确定为空**"，而这个判断是个守卫 ——
    /// 结果就是**所有状态上报被悄悄挡掉**，症状是界面永久停在 `.readyToPlay`
    /// 而画面尺寸/时长照报（**实测踩到**）。
    /// 判据：**"不确定"必须与"确定为零"分开处理** —— 守卫遇到不确定时应当放行。
    private func isPlaylistEmpty(_ handle: OpaquePointer) -> Bool {
        guard let count = getInt64(handle, "playlist-count") else { return false }
        return count == 0
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
        case "track-list/count":
            // `track-list` 一变，**字幕轨与视频轨都要重读**：一个属性、两条回读路径。
            // （逐条拼状态容易拼出不一致的中间态 —— 见 `refreshSubtitleState` 的说明。）
            refreshSubtitleState()
            refreshVideoTrackState()
        case "sid", "sub-visibility", "sub-delay":
            // 三条都走同一个"回读整份字幕状态"的路径：它们互相影响
            // （比如 `sid` 变了，`track-list/N/selected` 也变了），逐条拼状态容易拼出不一致的中间态。
            refreshSubtitleState()
        case "vid":
            refreshVideoTrackState()
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

    /// ⚠️ 内核日志**不进事件流**：`PlayerKernelEvent` 是给装配层消费的**契约**，
    /// 往里塞调试文本会污染它（而且 UI 得学会忽略）。日志走独立回调，用完即弃。
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
        case .videoTracksChanged(let state):
            videoTracks = state
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
        trackIndices(handle, ofType: "sub").map { index in
            let prefix = "track-list/\(index)"
            let codec = getString(handle, "\(prefix)/codec")
            return SubtitleTrack(
                id: getInt64(handle, "\(prefix)/id") ?? -1,
                title: getString(handle, "\(prefix)/title"),
                language: getString(handle, "\(prefix)/lang"),
                isExternal: getFlag(handle, "\(prefix)/external") ?? false,
                // 容器里的内挂字幕常常只报一个通用 `sub`，那不是编解码信息 ⇒ 置空。
                codec: codec == "sub" ? nil : codec
            )
        }
    }

    /// `track-list` 里 `type == <type>` 的那些下标。
    ///
    /// 字幕轨与视频轨**共用这一条过滤**（`docs/14` §一 的结论：「把 `type == "sub"` 的过滤条件泛化」）。
    /// 之所以能共用：HLS 的多码率档位在 mpv 里**就是若干条普通 `type=video` 的轨道** ——
    /// 它们与字幕轨走的是同一张 `track-list`，只是类型不同。
    private func trackIndices(_ handle: OpaquePointer, ofType type: String) -> [Int] {
        guard let count = getInt64(handle, "track-list/count"), count > 0 else { return [] }
        return (0..<Int(count)).filter { getString(handle, "track-list/\($0)/type") == type }
    }

    /// mpv 用**负值**表示"没有选中"（`sid=no`）—— 这里把它归一成 `nil`，
    /// 让上层只需要处理一种"没有"的表示法。
    private func readSelectedSubtitleTrackID(_ handle: OpaquePointer) -> Int64? {
        guard let sid = getInt64(handle, "sid"), sid >= 0 else { return nil }
        return sid
    }

    // MARK: - 视频轨状态回读（「可切清晰度」）

    /// 从内核**回读整份视频轨状态**，有变化才上报。与 `refreshSubtitleState` 同一条纪律：
    /// 一次读全、一次比较、一次上报（逐条更新会拼出"界面看得到但内核不认"的中间态）。
    private func refreshVideoTrackState() {
        guard let handle = owner?.pointer else { return }
        let next = PlayerVideoTrackState(
            tracks: readVideoTracks(handle),
            selectedTrackID: readSelectedVideoTrackID(handle)
        )
        guard next != videoTracks else { return }
        videoTracks = next
        emit(.videoTracksChanged(next))
    }

    /// 枚举视频轨。
    ///
    /// ⚠️ 档位标签取 **`demux-w` / `demux-h`**，不取 `video-params/*`：
    /// 后者只描述**当前正在解的那一条**，拿它当"每条轨的分辨率"读出来全会是同一个值。
    ///
    /// ⚠️ 也不押 `hls-bitrate`：实测在 HLS 源上**读不到**（`-99`，见 `docs/14` §1.2）。
    /// 这里读 `demux-bitrate` 且**读不到 / 非正数就留 `nil`** —— 界面上"有就显示"，
    /// 分辨率才是那个稳定可得的档位区分。
    private func readVideoTracks(_ handle: OpaquePointer) -> [VideoTrack] {
        trackIndices(handle, ofType: "video").map { index in
            let prefix = "track-list/\(index)"
            let bitrate = getInt64(handle, "\(prefix)/demux-bitrate")
            return VideoTrack(
                id: getInt64(handle, "\(prefix)/id") ?? -1,
                width: Int(getInt64(handle, "\(prefix)/demux-w") ?? 0),
                height: Int(getInt64(handle, "\(prefix)/demux-h") ?? 0),
                codec: getString(handle, "\(prefix)/codec"),
                bitrate: bitrate.flatMap { $0 > 0 ? Int($0) : nil }
            )
        }
    }

    /// 与字幕轨同样的"归一成 `nil`"：mpv 的 `vid` 在没有视频时是**负值**（`-1`）。
    private func readSelectedVideoTrackID(_ handle: OpaquePointer) -> Int64? {
        guard let vid = getInt64(handle, "vid"), vid >= 0 else { return nil }
        return vid
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

    /// 设置一个 mpv 选项。
    ///
    /// ⚠️ **必须检查返回值**：选项名拼错、或当前 mpv 版本不认识它时，
    /// `mpv_set_option_string` 只是**返回负值** —— 不抛异常、不打印、不报错。
    /// 那个选项就**静默不生效**，而代码看上去完全正确（`P-049` 同一族）。
    /// 失败的项记进 `rejectedOptions`，测试据此断言"我设的每一项 mpv 都认"。
    @discardableResult
    private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) -> Bool {
        let status = mpv_set_option_string(handle, name, value)
        guard status >= 0 else {
            rejectedOptions.append("\(name)=\(value)")
            return false
        }
        return true
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
