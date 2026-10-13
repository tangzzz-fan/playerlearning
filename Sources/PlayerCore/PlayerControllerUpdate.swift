import CoreGraphics

public enum PlayerControllerUpdate: Sendable, Equatable {
    case stateChanged(PlayerState)
    case timeChanged(PlayerTimeUpdate)
    case bufferingChanged(Bool)
    case videoSizeChanged(CGSize)
}
