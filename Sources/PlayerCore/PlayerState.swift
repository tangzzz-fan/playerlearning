public enum PlayerState: Sendable, Equatable {
    case idle
    case preparing
    case readyToPlay
    case playing
    case paused
    case finished
    case failed
}
