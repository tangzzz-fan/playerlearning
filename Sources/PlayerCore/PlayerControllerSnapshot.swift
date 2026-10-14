import CoreGraphics

public struct PlayerControllerSnapshot: Sendable, Equatable {
    public var state: PlayerState
    public var currentTime: Double
    public var duration: Double
    public var isBuffering: Bool
    /// 视频原始像素尺寸；未知时为 `.zero`。
    public var naturalSize: CGSize
    public var audio: PlayerAudioState
    public var subtitles: PlayerSubtitleState

    public init(
        state: PlayerState = .idle,
        currentTime: Double = 0,
        duration: Double = 0,
        isBuffering: Bool = false,
        naturalSize: CGSize = .zero,
        audio: PlayerAudioState = PlayerAudioState(),
        subtitles: PlayerSubtitleState = PlayerSubtitleState()
    ) {
        self.state = state
        self.currentTime = currentTime
        self.duration = duration
        self.isBuffering = isBuffering
        self.naturalSize = naturalSize
        self.audio = audio
        self.subtitles = subtitles
    }
}
