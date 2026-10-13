/// 全屏状态（纯逻辑）。
///
/// 单独成类型而不是在 View 里放一个 `@State var isFullscreen`：
/// 它有两个**不显眼**的规则要守 —— 全屏时宿主外壳要一起让位；
/// 退出播放器时必须复位（否则下次进来还是全屏，用户会以为界面坏了）。
public struct PlayerFullscreenModel: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case inline
        case fullscreen
    }

    public private(set) var mode: Mode = .inline

    public init() {}

    public mutating func toggle() {
        mode = mode == .inline ? .fullscreen : .inline
    }

    /// 全屏时**宿主外壳**（导航栏、状态栏、调试按钮）要让位 —— 不只是画面变大。
    public var hidesHostChrome: Bool { mode == .fullscreen }

    /// 退出播放器时复位。**必须做**：否则下次进来会一开屏就是全屏。
    public mutating func reset() {
        mode = .inline
    }
}
