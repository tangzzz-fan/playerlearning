import CoreGraphics

public struct PlayerKernelSnapshot: Sendable, Equatable {
    public var state: PlayerState
    public var currentTime: Double
    public var duration: Double
    public var isBuffering: Bool
    /// 视频原始像素尺寸；未知时为 `.zero`。UI 摆画面比例要用。
    public var naturalSize: CGSize

    public init(
        state: PlayerState = .idle,
        currentTime: Double = 0,
        duration: Double = 0,
        isBuffering: Bool = false,
        naturalSize: CGSize = .zero
    ) {
        self.state = state
        self.currentTime = currentTime
        self.duration = duration
        self.isBuffering = isBuffering
        self.naturalSize = naturalSize
    }
}
