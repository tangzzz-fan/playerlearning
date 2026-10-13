import CoreGraphics

public enum PlayerKernelEvent: Sendable, Equatable {
    case stateChanged(PlayerState)
    case currentTimeChanged(Double)
    case durationChanged(Double)
    case bufferingChanged(Bool)
    case videoSizeChanged(CGSize)
    case audioChanged(PlayerAudioState)
}
