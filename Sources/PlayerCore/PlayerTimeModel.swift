public struct PlayerTimeModel: Sendable {
    public static let intervalRange: ClosedRange<Double> = 0.2...1.0
    public static let defaultInterval: Double = 0.25

    public let interval: Double
    public private(set) var currentTime: Double
    public private(set) var duration: Double

    private var lastPublishedTime: Double?

    public init(interval: Double = PlayerTimeModel.defaultInterval, duration: Double = 0) {
        self.interval = Self.normalizedInterval(interval)
        self.currentTime = 0
        self.duration = Self.normalizedDuration(duration)
    }

    @discardableResult
    public mutating func apply(_ event: PlayerKernelEvent) -> PlayerTimeUpdate? {
        switch event {
        case .currentTimeChanged(let seconds):
            currentTime = seconds
            return publishIfDue()
        case .durationChanged(let seconds):
            duration = Self.normalizedDuration(seconds)
            return publish()
        case .stateChanged, .bufferingChanged, .videoSizeChanged, .audioChanged:
            return nil
        }
    }

    public func clampSeekTarget(_ seconds: Double) -> Double {
        guard !seconds.isNaN else { return 0 }
        let lowerBounded = Swift.max(0, seconds)
        guard duration > 0 else {
            return lowerBounded.isFinite ? lowerBounded : 0
        }
        return Swift.min(lowerBounded, duration)
    }

    public func updates(from events: AsyncStream<PlayerKernelEvent>) -> AsyncStream<PlayerTimeUpdate> {
        AsyncStream { continuation in
            let task = Task {
                var model = self
                for await event in events {
                    if let update = model.apply(event) {
                        continuation.yield(update)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private mutating func publishIfDue() -> PlayerTimeUpdate? {
        if let lastPublishedTime, abs(currentTime - lastPublishedTime) < interval {
            return nil
        }
        return publish()
    }

    private mutating func publish() -> PlayerTimeUpdate {
        lastPublishedTime = currentTime
        return PlayerTimeUpdate(currentTime: currentTime, duration: duration)
    }

    private static func normalizedInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultInterval }
        return Swift.min(Swift.max(seconds, intervalRange.lowerBound), intervalRange.upperBound)
    }

    private static func normalizedDuration(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 0
    }
}
