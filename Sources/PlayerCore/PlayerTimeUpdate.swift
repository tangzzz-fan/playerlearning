public struct PlayerTimeUpdate: Sendable, Equatable {
    public var currentTime: Double
    public var duration: Double

    public init(currentTime: Double, duration: Double) {
        self.currentTime = currentTime
        self.duration = duration
    }
}
