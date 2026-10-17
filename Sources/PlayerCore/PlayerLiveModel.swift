public struct PlayerLiveModel: Sendable {
    public static let growthThreshold: Double = 2.0
    public static let elapsedRequired: Double = 1.0
    public static let unknownDurationSeconds: Double = 3.0

    public private(set) var isLive: Bool

    private var baseline: (duration: Double, currentTime: Double)?
    private var unknownDurationStart: Double?

    public init() {
        self.isLive = false
        self.baseline = nil
        self.unknownDurationStart = nil
    }

    public mutating func observe(duration: Double, currentTime: Double) {
        guard !isLive else { return }
        let normalized = duration.isFinite && duration > 0 ? duration : 0
        guard normalized > 0 else {
            guard currentTime.isFinite, currentTime > 0 else { return }
            if let start = unknownDurationStart {
                if currentTime - start >= Self.unknownDurationSeconds {
                    isLive = true
                }
            } else {
                unknownDurationStart = currentTime
            }
            return
        }
        unknownDurationStart = nil
        guard let baseline else {
            self.baseline = (normalized, currentTime)
            return
        }
        guard normalized - baseline.duration >= Self.growthThreshold else { return }
        guard currentTime - baseline.currentTime >= Self.elapsedRequired else { return }
        isLive = true
    }
}
