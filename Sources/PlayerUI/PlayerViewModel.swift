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

    /// 是否成功加载过资源。
    ///
    /// **它决定控制按钮能不能按**，因为"没加载过"时所有播放控制的调用都是**静默失败**的：
    /// 内核连 mpv 句柄都还没创建（`owner == nil`），`play()` / `pause()` / `stop()` 全部直接 return。
    /// 症状是**"点了没反应，也不报错"** —— 用户只会以为界面坏了。
    ///
    /// 与其让他对着一个不动的按钮猜，不如让它**看起来就不能按**。
    public private(set) var hasLoadedResource = false

    /// 诊断挂钩：把**原始**更新原样吐出去。端到端脚本与 UI 测试靠它判断真实时序
    /// （而不是靠截屏猜）。默认 `nil`，**不参与任何播放决策**。
    public var onUpdate: (@MainActor (PlayerControllerUpdate) -> Void)?

    /// 拖拽策略（纯逻辑）。
    public private(set) var scrub = PlayerScrubModel()
    /// 全屏状态（纯逻辑）。
    public private(set) var fullscreen = PlayerFullscreenModel()
    /// 控制层显隐（纯逻辑）。点画面 toggle，播放中自动隐藏，暂停时保持显示。
    public private(set) var chrome = PlayerChromeModel()
    /// 字幕状态（轨道清单 / 选中项 / 开关 / 延迟）。**来自内核**，不是界面自己记的。
    public private(set) var subtitles = PlayerSubtitleState()
    /// 视频轨状态（档位清单 / 当前档位）= 界面上的「清晰度」。**同样来自内核**。
    public private(set) var videoTracks = PlayerVideoTrackState()
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

    /// 能不能播/暂停。**没加载过文件时为 `false`** —— 理由见 `hasLoadedResource`。
    public var canPlay: Bool { hasLoadedResource }

    /// 能不能停。已经在 `.idle` 时没必要停（停了也没有变化可看）。
    public var canStop: Bool { hasLoadedResource && state != .idle }

    /// 能不能快进/快退。
    public var canSkip: Bool { hasLoadedResource && duration > 0 }

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

    /// 打开内核自己的日志（排查用，见 `PlayerKernelProtocol` 之外的 `MPVKernel.enableLogging`）。
    ///
    /// ⚠️ 它**刻意不放进 `PlayerKernelProtocol`**：那是所有内核都要满足的契约，
    /// 而"转发内核日志"是**内核特有的诊断能力**（不同内核的日志机制完全不同）。
    /// 为了让它进协议而给协议加一个 `FakeKernel` 也要假装实现的成员，是本末倒置。
    public func enableKernelLogging(_ handler: @escaping @Sendable (String) -> Void) async {
        await controller.enableKernelLogging(handler)
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

    /// 全屏**置位**（幂等）。给快捷键的「退出全屏」用 ——
    /// 那个命令表达的是"要回到非全屏"，而不是"翻一下"（连按两次不该又进全屏）。
    public func setFullscreen(_ value: Bool) {
        guard fullscreen.isFullscreen != value else { return }
        fullscreen.setFullscreen(value)
    }

    /// 快捷键的**唯一副作用入口** —— 界面层只负责"把按键翻成命令"，判断全在这里。
    ///
    /// 为什么不把副作用写在 View 里：这些命令里有几条**不是无脑转发**
    /// （退出全屏只该在按的时候生效、跳转要基于当前时间算目标），
    /// 而 View 是**测不到**的 —— UI 自动化（`Demo/UITests`）能证"点到了没"，
    /// 但证不了"算错了没"：它跑一次几十秒，而这里每条分支都能毫秒级钉住。
    ///
    /// ## 两类命令，界线是"它需不需要内核"
    /// - **需要内核的**（播放/暂停 · 停止 · 跳转）：判据**与按钮完全共用**
    ///   （`canPlay` / `canStop` / `canSkip`）—— 按钮灰着的时候，对应的快捷键也不该有反应，
    ///   否则"键盘能用、按钮不能用"会让人以为界面坏了。
    /// - **纯界面的**（全屏 / 退出全屏）：**任何时候都响应** —— 它跟有没有视频无关，
    ///   而"按了 F 没反应"比"没得看"更让人困惑。
    public func handleShortcut(_ command: PlayerShortcutCommand) async {
        switch command {
        case .toggleFullscreen:
            fullscreen.toggle()
        case .exitFullscreen:
            setFullscreen(false)
        case .togglePlayPause:
            guard canPlay else { return }
            await togglePlayPause()
        case .stop:
            guard canStop else { return }
            await stop()
        case .skipBackward:
            guard canSkip else { return }
            await skip(by: -PlayerShortcuts.skipStep)
        case .skipForward:
            guard canSkip else { return }
            await skip(by: PlayerShortcuts.skipStep)
        }
    }

    /// 点画面：显示 ↔ 隐藏控制层。
    public func toggleChrome() {
        chrome.toggle()
    }

    /// 拖拽 / 菜单期间按住控制层，不让它自动消失。
    public func beginChromeHold() {
        chrome.beginHoldingOpen()
    }

    public func endChromeHold() {
        chrome.endHoldingOpen()
    }

    /// 自动隐藏计时到点。返回**是否真的隐藏了** —— `false` 时调用方不该再排队下一次计时
    /// （否则一个隐藏不了的界面会永远空转计时器）。
    @discardableResult
    public func autoHideChrome() -> Bool {
        chrome.autoHide(isPlaying: isPlaying)
    }

    /// 开关取反：**只发命令**，状态等内核回执（`sub-visibility` 是可观测属性 —— 同 `P2-T5` 的原则）。
    public func toggleSubtitles() async {
        await controller.toggleSubtitleVisibility()
    }

    public func selectSubtitleTrack(id: Int64?) async {
        await controller.selectSubtitleTrack(id: id)
    }

    /// 切清晰度。**只发命令**，当前档位等内核回读（同字幕轨选择的原则）。
    public func selectVideoTrack(id: Int64) async {
        await controller.selectVideoTrack(id: id)
    }

    public func adjustSubtitleDelay(by delta: Double) async {
        await controller.adjustSubtitleDelay(by: delta)
    }

    /// 加载一条外挂字幕：读 → 解编码 → 以 UTF-8 另存 → 交给内核。
    /// 失败时**如实报出来**，不静默（否则用户只会看到"字幕没反应"）。
    public func loadSubtitle(from url: URL) async {
        // 没有文件时挂字幕是无处可挂的（内核连句柄都没建）⇒ 明说，别让它静默失败。
        guard hasLoadedResource else {
            subtitleNote = "先打开一个视频，再加载字幕"
            return
        }
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
            // 命令发出去了就记下来 —— 之后 `play()` 才有东西可以"重新放回去"。
            hasLoadedResource = true
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
    ///
    /// ⚠️ 这个方法是**同步**的，故意的。视图层的手势回调是同步的：
    /// `onBegan()` 之后**紧接着**就是 `onChanged()`。如果这里 `await` 一下（原来的写法），
    /// 拖拽状态要等下一个 runloop 才确立，而 `updateScrub` 里的 `guard isScrubbing`
    /// 会把**第一下点击整个丢掉** —— 症状正是"点进度条没反应，要拖才生效"。
    /// 暂停是内核动作，可以异步发；**拖拽状态必须当场确立**。
    public func beginScrub() {
        guard !scrub.isScrubbing else { return }
        // 拖拽期间控制层必须留着：手指还在滑块上，层没了就没法继续拖。
        chrome.beginHoldingOpen()
        scrub.begin(currentTime: currentTime, isPlaying: isPlaying)
        if scrub.wasPlayingBeforeScrub {
            Task { await controller.pause() }
        }
    }

    /// 拖动中：只更新预览，**不发 seek** —— 拖拽过程中每次移动都 seek 会把内核打爆。
    public func updateScrub(fraction: Double) {
        scrub.update(fraction: fraction, duration: duration)
    }

    /// 松手：**这一次**才发 seek；本来在播就恢复播放。
    public func endScrub() {
        // 先松"按住"：下面的 guard 可能提前返回，漏掉它会让控制层**永远不自动隐藏**。
        chrome.endHoldingOpen()
        let shouldResume = scrub.wasPlayingBeforeScrub
        guard let target = scrub.end() else { return }
        Task {
            await controller.seek(to: target)
            if shouldResume {
                await controller.play()
            }
        }
    }
    public func skip(by delta: Double) async { await controller.seek(to: currentTime + delta) }

    private func apply(_ update: PlayerControllerUpdate) {
        onUpdate?(update)
        switch update {
        case .stateChanged(let newState):
            state = newState
            // 一旦不在播放，就把控制层露出来 —— 暂停 / 就绪 / 播完 / 失败时用户多半要操作，
            // 那正是最不该"点完就收走"的时刻。
            if newState != .playing {
                chrome.show()
            }
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
        case .videoTracksChanged(let newState):
            videoTracks = newState
        }
    }

    private func endUpdates() {
        pump?.cancel()
        pump = nil
    }
}
