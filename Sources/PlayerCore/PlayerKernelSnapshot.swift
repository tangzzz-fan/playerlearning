import CoreGraphics

public struct PlayerKernelSnapshot: Sendable, Equatable {
    public var state: PlayerState
    public var currentTime: Double
    public var duration: Double
    public var isBuffering: Bool
    /// 视频原始像素尺寸；未知时为 `.zero`。UI 摆画面比例要用。
    public var naturalSize: CGSize
    /// 音频链路状态（解码端 / 输出端采样率）。
    public var audio: PlayerAudioState
    /// 字幕状态（轨道清单 / 选中项 / 开关 / 延迟）。
    public var subtitles: PlayerSubtitleState
    /// 视频轨状态（档位清单 / 当前档位）。
    public var videoTracks: PlayerVideoTrackState

    public init(
        state: PlayerState = .idle,
        currentTime: Double = 0,
        duration: Double = 0,
        isBuffering: Bool = false,
        naturalSize: CGSize = .zero,
        audio: PlayerAudioState = PlayerAudioState(),
        subtitles: PlayerSubtitleState = PlayerSubtitleState(),
        videoTracks: PlayerVideoTrackState = PlayerVideoTrackState()
    ) {
        self.state = state
        self.currentTime = currentTime
        self.duration = duration
        self.isBuffering = isBuffering
        self.naturalSize = naturalSize
        self.audio = audio
        self.subtitles = subtitles
        self.videoTracks = videoTracks
    }
}
