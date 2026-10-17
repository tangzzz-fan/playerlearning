import CoreGraphics
import Foundation

public actor PlayerController {
    private let kernel: any PlayerKernelProtocol
    private var machine: PlayerStateMachine
    private var time: PlayerTimeModel
    private var isBuffering = false
    private var naturalSize: CGSize = .zero
    private var audio = PlayerAudioState()
    private var subtitles = PlayerSubtitleState()
    private var videoTracks = PlayerVideoTrackState()
    private var continuation: AsyncStream<PlayerControllerUpdate>.Continuation?
    private var pump: Task<Void, Never>?

    public init(kernel: any PlayerKernelProtocol, timeInterval: Double = PlayerTimeModel.defaultInterval) {
        self.kernel = kernel
        machine = PlayerStateMachine()
        time = PlayerTimeModel(interval: timeInterval)
    }

    /// 建立更新流并开始消费内核事件。重复调用会结束上一条流（避免旧消费者永久挂死）。
    @discardableResult
    public func start() async -> AsyncStream<PlayerControllerUpdate> {
        endUpdates()

        let (stream, continuation) = AsyncStream<PlayerControllerUpdate>.makeStream()
        self.continuation = continuation

        let events = await kernel.events()
        pump = Task { [weak self] in
            for await event in events {
                await self?.consume(event)
            }
            await self?.endUpdates()
        }
        return stream
    }

    public func snapshot() -> PlayerControllerSnapshot {
        PlayerControllerSnapshot(
            state: machine.state,
            currentTime: time.currentTime,
            duration: time.duration,
            isBuffering: isBuffering,
            naturalSize: naturalSize,
            audio: audio,
            subtitles: subtitles,
            videoTracks: videoTracks
        )
    }

    public func load(_ resource: PlayerResource) async throws {
        time.resetLiveDetection()
        try await kernel.load(resource)
    }

    public func play() async {
        await kernel.play()
    }

    public func pause() async {
        await kernel.pause()
    }

    public func stop() async {
        await kernel.stop()
    }

    public func seek(to seconds: Double) async {
        await kernel.seek(to: time.clampSeekTarget(seconds))
    }

    /// 加一条外挂字幕。**`title` 传文件名**：内核拿不到更友好的名字，界面上也总得有个字。
    public func addSubtitle(url: URL, title: String? = nil) async {
        await kernel.addSubtitle(url: url, title: title ?? url.lastPathComponent)
    }

    public func selectSubtitleTrack(id: Int64?) async {
        await kernel.selectSubtitleTrack(id: id)
    }

    /// 切清晰度（= 切视频轨）。
    ///
    /// **转发即完，不本地乐观改状态** —— 与字幕轨选择同一条理由：
    /// 内核可能**不接受**这次选择（id 已失效 / 该档已被清掉），
    /// 而状态最终以内核回读为准。乐观上报在这里会说谎：
    /// 界面显示"已切到 480p"而画面还是 720p —— 用户会当成 bug。
    public func selectVideoTrack(id: Int64) async {
        await kernel.selectVideoTrack(id: id)
    }

    /// 可见性：**本地先生效，再以内核回执为准**。
    ///
    /// 这与 `play()/pause()` 的处理**相反**，理由是两者性质不同：
    /// `pause` 可能被内核**拒绝**（缓存中 / EOF / `keep-open` 都会让它自己改主意）⇒ 乐观上报会说谎；
    /// 而 `sub-visibility` 是一个无条件生效的可设置属性，**我们知道自己发下去的是什么**。
    /// 本地先生效换来的是：连续点击不会被几百微秒的回执延迟吃掉，
    /// 而一旦内核回执不同（例如被钳制），它会覆盖本地值 —— **自我纠正**。
    public func setSubtitleVisible(_ visible: Bool) async {
        guard subtitles.isVisible != visible else { return }
        await kernel.setSubtitleVisible(visible)
        subtitles.isVisible = visible
        continuation?.yield(.subtitlesChanged(subtitles))
    }

    /// 开关取反。**当前状态由控制器持有**（它消费内核事件），所以这个判断不放在界面层。
    public func toggleSubtitleVisibility() async {
        await setSubtitleVisible(!subtitles.isVisible)
    }

    /// 延迟：**钳制在这里做**（目标区间属于模型知识），内核只管执行。
    ///
    /// 本地即时生效的理由与 `setSubtitleVisible` 相同，但在**相对**调整上更硬：
    /// 若每次都等回执，连点 `+0.5 s` 五次会全部基于同一个陈旧值计算 ⇒
    /// **用户按了五下，字幕只挪了 0.5 秒**。那不是延迟不准，是操作丢失。
    public func setSubtitleDelay(_ seconds: Double) async {
        let clamped = SubtitleTimeline.normalizeDelay(seconds)
        guard clamped != subtitles.delay else { return }
        await kernel.setSubtitleDelay(clamped)
        subtitles.delay = clamped
        continuation?.yield(.subtitlesChanged(subtitles))
    }

    public func adjustSubtitleDelay(by delta: Double) async {
        await setSubtitleDelay(subtitles.delay + delta)
    }

    /// 转发"打开内核日志"这个请求。
    ///
    /// 内核不支持时是 **no-op**（协议给了默认实现）—— 装配层与界面不必判断"这个内核会不会吐日志"。
    public func enableKernelLogging(_ handler: @escaping @Sendable (String) -> Void) async {
        await kernel.enableLogging(handler)
    }

    public func finishUpdates() {
        endUpdates()
    }

    private func consume(_ event: PlayerKernelEvent) {
        switch event {
        case .stateChanged(let newState):
            guard machine.transition(to: newState) == .applied else { return }
            continuation?.yield(.stateChanged(newState))
            // 播完 ⇒ 把位置推到片尾。`time-pos` 到 EOF 就不再更新，最后报来的是**末帧的时间戳**，
            // 少这一步进度条走不满、时间停在「04/05」（真机实测）。
            if newState == .finished, let update = time.snapToEnd() {
                continuation?.yield(.timeChanged(update))
            }
        case .currentTimeChanged, .durationChanged:
            guard let update = time.apply(event) else { return }
            continuation?.yield(.timeChanged(update))
        case .bufferingChanged(let flag):
            guard flag != isBuffering else { return }
            isBuffering = flag
            continuation?.yield(.bufferingChanged(flag))
        case .videoSizeChanged(let size):
            guard size != naturalSize else { return }
            naturalSize = size
            continuation?.yield(.videoSizeChanged(size))
        case .audioChanged(let state):
            guard state != audio else { return }
            audio = state
            continuation?.yield(.audioChanged(state))
        case .subtitlesChanged(let state):
            guard state != subtitles else { return }
            subtitles = state
            continuation?.yield(.subtitlesChanged(state))
        case .videoTracksChanged(let state):
            guard state != videoTracks else { return }
            videoTracks = state
            continuation?.yield(.videoTracksChanged(state))
        }
    }

    private func endUpdates() {
        pump?.cancel()
        continuation?.finish()
        continuation = nil
        pump = nil
    }
}
