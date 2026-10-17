public struct PlayerTimeUpdate: Sendable, Equatable {
    public var currentTime: Double
    public var duration: Double
    public var isLive: Bool

    public init(currentTime: Double, duration: Double, isLive: Bool = false) {
        self.currentTime = currentTime
        self.duration = duration
        self.isLive = isLive
    }
}
