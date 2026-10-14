import CoreGraphics
import Foundation
import Observation
import PlayerCore

/// 把 `PlayerController` 的更新流桥到 SwiftUI 的**壳**。
///
/// 为什么放在 `PlayerUI` 而不是 `PlayerCore`：它是 UI 关注点（`@Observable` 驱动重绘），
/// 而 `PlayerCore` 必须保持零 UI 依赖（门禁第 1 项就是查它）。
/// 它**不认识任何内核**（只依赖 `PlayerController`）⇒ `PlayerUI` 不需要引用 libmpv，
/// 装配（选哪个内核、句柄从哪来）留在 App 层。
@MainActor
@Observable
public final class PlayerViewModel {
    public private(set) var state: PlayerState = .idle
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var naturalSize: CGSize = .zero
    public private(set) var audio = PlayerAudioState()
    public private(set) var isBuffering = false
    /// 加载失败的原因（给人看的一行字）。`nil` 表示没失败。
    public private(set) var loadFailure: String?

    /// 诊断挂钩：把**原始**更新原样吐出去。端到端脚本与 UI 测试靠它判断真实时序
    /// （而不是靠截屏猜）。默认 `nil`，**不参与任何播放决策**。
    public var onUpdate: (@MainActor (PlayerControllerUpdate) -> Void)?

    /// 拖拽策略（纯逻辑）。
    public private(set) var scrub = PlayerScrubModel()
    /// 全屏状态（纯逻辑）。
    public private(set) var fullscreen = PlayerFullscreenModel()
    /// 字幕状态（轨道清单 / 选中项 / 开关 / 延迟）。**来自内核**，不是界面自己记的。
    public private(set) var subtitles = PlayerSubtitleState()
    /// 字幕加载结果的一行字（编码 / 格式 / 丢了几块）。
    public private(set) var subtitleNote: String?

    /// 安全作用域访问记账（外部文件必须持有访问权，且换文件时才释放）。
    private var fileAccess = PlayerSecurityScopedAccess()

    private let controller: PlayerController
    private var pump: Task<Void, Never>?

    public init(controller: PlayerController) {
        self.controller = controller
    }

    public var isPlaying: Bool { state == .playing }

    /// 当前持有安全作用域访问权的文件 URL（`nil` = 没有）。
    /// 只读窗口：**没有它，"换文件时有没有申请/释放访问权"就是不可验证的**
    /// （变异测试正是靠它抓到"begin 被删掉也全绿"）。
    public var accessedFileURL: URL? { fileAccess.active }
    

    /// 进度比例 `0…1`。时长未知时给 `0` —— **不是 `NaN`**：`NaN` 会让进度条布局直接崩。
    public var progress: Double {
        guard duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// 界面上该显示的时间：拖拽时显示**预览**，否则显示真实播放位置。
    /// 两者分开，是为了让"手指底下的数字"不受内核时间流干扰（否则会跟手打架）。
    public var displayTime: Double {
        scrub.isScrubbing ? scrub.previewTime : currentTime
    }

    /// 界面上该显示的进度 `0…1`。拖拽时按预览时间算。
    public var displayProgress: Double {
        guard scrub.isScrubbing else { return progress }
        guard duration > 0 else { return 0 }
        return min(max(scrub.previewTime / duration, 0), 1)
    }

    /// 能不能拖：时长未知时不给拖（拖了也不知道拖到哪）。
    public var canScrub: Bool { duration > 0 }

    /// 画面宽高比；尺寸未知时退回 16:9（避免首帧前布局跳一下）。
    public var aspectRatio: Double {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return 16.0 / 9.0 }
        return naturalSize.width / naturalSize.height
    }

    public func start() async {
        endUpdates()
        let updates = await controller.start()
        pump = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.apply(update)
            }
        }
        let snapshot = await controller.snapshot()
        state = snapshot.state
    }

    public func teardown() async {
        endUpdates()
        // 退出播放器必须复位全屏：否则下次进来一开屏就是全屏，用户会以为界面坏了。
        fullscreen.reset()
        if let previous = fileAccess.end() {
            previous.stopAccessingSecurityScopedResource()
        }
        // 字幕副本不留在磁盘上：残留会让人以为"字幕是自己冒出来的"。
        SubtitleLoader.cleanUp()
        subtitleNote = nil
        await controller.finishUpdates()
    }

    public func toggleFullscreen() {
        fullscreen.toggle()
    }

    /// 开关取反：**只发命令**，状态等内核回执（`sub-visibility` 是可观测属性 —— 同 `P2-T5` 的原则）。
    public func toggleSubtitles() async {
        await controller.toggleSubtitleVisibility()
    }

    public func selectSubtitleTrack(id: Int64?) async {
        await controller.selectSubtitleTrack(id: id)
    }

    public func adjustSubtitleDelay(by delta: Double) async {
        await controller.adjustSubtitleDelay(by: delta)
    }

    /// 加载一条外挂字幕：读 → 解编码 → 以 UTF-8 另存 → 交给内核。
    /// 失败时**如实报出来**，不静默（否则用户只会看到"字幕没反应"）。
    public func loadSubtitle(from url: URL) async {
        do {
            let prepared = try SubtitleLoader.prepare(url: url)
            subtitleNote = prepared.summary
            await controller.addSubtitle(url: prepared.url, title: url.lastPathComponent)
        } catch SubtitleLoadError.undecodable {
            subtitleNote = "字幕编码认不出来（已中止，避免显示乱码）"
        } catch {
            subtitleNote = "字幕读取失败：\(error)"
        }
    }

    public func load(_ resource: PlayerResource) async {
        loadFailure = nil
        // 换文件：先接住新文件的访问权，再释放上一个（顺序反了会在切换瞬间读不到旧文件）。
        if let previous = fileAccess.begin(resource.url) {
            previous.stopAccessingSecurityScopedResource()
        }
        do {
            try await controller.load(resource)
        } catch {
            loadFailure = String(describing: error)
        }
    }

    public func togglePlayPause() async {
        if isPlaying {
            await controller.pause()
        } else {
            await controller.play()
        }
    }

    public func play() async { await controller.play() }
    public func pause() async { await controller.pause() }
    public func stop() async { await controller.stop() }
    public func seek(to seconds: Double) async { await controller.seek(to: seconds) }

    /// 按下进度条：**先暂停**。不暂停的话，手指还在拖、声音还在往前走，听起来像坏了。
    public func beginScrub() async {
        guard !scrub.isScrubbing else { return }
        scrub.begin(currentTime: currentTime, isPlaying: isPlaying)
        if scrub.wasPlayingBeforeScrub {
            await controller.pause()
        }
    }

    /// 拖动中：只更新预览，**不发 seek** —— 拖拽过程中每次移动都 seek 会把内核打爆。
    public func updateScrub(fraction: Double) {
        scrub.update(fraction: fraction, duration: duration)
    }

    /// 松手：**这一次**才发 seek；本来在播就恢复播放。
    public func endScrub() async {
        let shouldResume = scrub.wasPlayingBeforeScrub
        guard let target = scrub.end() else { return }
        await controller.seek(to: target)
        if shouldResume {
            await controller.play()
        }
    }
    public func skip(by delta: Double) async { await controller.seek(to: currentTime + delta) }

    private func apply(_ update: PlayerControllerUpdate) {
        onUpdate?(update)
        switch update {
        case .stateChanged(let newState):
            state = newState
        case .timeChanged(let time):
            currentTime = time.currentTime
            duration = time.duration
        case .bufferingChanged(let flag):
            isBuffering = flag
        case .videoSizeChanged(let size):
            naturalSize = size
        case .audioChanged(let newState):
            audio = newState
        case .subtitlesChanged(let newState):
            subtitles = newState
        }
    }

    private func endUpdates() {
        pump?.cancel()
        pump = nil
    }
}
