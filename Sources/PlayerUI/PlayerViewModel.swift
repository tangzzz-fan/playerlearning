import CoreGraphics
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

    private let controller: PlayerController
    private var pump: Task<Void, Never>?

    public init(controller: PlayerController) {
        self.controller = controller
    }

    public var isPlaying: Bool { state == .playing }

    /// 进度比例 `0…1`。时长未知时给 `0` —— **不是 `NaN`**：`NaN` 会让进度条布局直接崩。
    public var progress: Double {
        guard duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

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
        await controller.finishUpdates()
    }

    public func load(_ resource: PlayerResource) async {
        loadFailure = nil
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
        }
    }

    private func endUpdates() {
        pump?.cancel()
        pump = nil
    }
}
