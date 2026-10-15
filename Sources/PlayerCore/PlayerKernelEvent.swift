import CoreGraphics

public enum PlayerKernelEvent: Sendable, Equatable {
    case stateChanged(PlayerState)
    case currentTimeChanged(Double)
    case durationChanged(Double)
    case bufferingChanged(Bool)
    case videoSizeChanged(CGSize)
    case audioChanged(PlayerAudioState)
    case subtitlesChanged(PlayerSubtitleState)
    /// 视频轨清单 / 当前档位变了（HLS 多码率的「清晰度」就是它）。
    case videoTracksChanged(PlayerVideoTrackState)
}
