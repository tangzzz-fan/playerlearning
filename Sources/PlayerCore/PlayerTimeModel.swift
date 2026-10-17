public struct PlayerTimeModel: Sendable {
    public static let intervalRange: ClosedRange<Double> = 0.2...1.0
    public static let defaultInterval: Double = 0.25

    public let interval: Double
    public private(set) var currentTime: Double
    public private(set) var duration: Double

    private var lastPublishedTime: Double?
    private var live = PlayerLiveModel()

    public init(interval: Double = PlayerTimeModel.defaultInterval, duration: Double = 0) {
        self.interval = Self.normalizedInterval(interval)
        self.currentTime = 0
        self.duration = Self.normalizedDuration(duration)
    }

    public var isLive: Bool { live.isLive }

    /// 换文件时把直播判定清零。
    ///
    /// **只清判定、不动 `currentTime` / `duration`**：那两项由新资源自己的
    /// `durationChanged` 覆盖，而`isLive` 一旦为真就**粘住**（直播不会变回点播，
    /// 这是判定规则的一半）—— 不清的话，先播直播再开本地文件，VOD 也会显示 LIVE。
    public mutating func resetLiveDetection() {
        live = PlayerLiveModel()
    }

    @discardableResult
    public mutating func apply(_ event: PlayerKernelEvent) -> PlayerTimeUpdate? {
        switch event {
        case .currentTimeChanged(let seconds):
            currentTime = seconds
            live.observe(duration: duration, currentTime: currentTime)
            return publishIfDue()
        case .durationChanged(let seconds):
            duration = Self.normalizedDuration(seconds)
            live.observe(duration: duration, currentTime: currentTime)
            return publish()
        case .stateChanged, .bufferingChanged, .videoSizeChanged, .audioChanged, .subtitlesChanged,
             .videoTracksChanged:
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

    /// 播完时把位置**对齐到片尾**。返回 `nil` = 不需要对齐（未知时长 / 已经在片尾）。
    ///
    /// 为什么需要它（真机实测）：`time-pos` 到 EOF 就**不再更新**，
    /// 内核最后上报的是**末帧的时间戳** —— 52.208 秒的片子停在 51.9。
    /// 于是进度条永远差一截（走不满）、时间显示停在「04/05」。
    ///
    /// 为什么不放在内核里：内核只负责**转述 mpv 报了什么**；
    /// 「结束就意味着位置等于时长」是**播放语义**，属于装配层（与 `seek` 钳制同一条原则）。
    @discardableResult
    public mutating func snapToEnd() -> PlayerTimeUpdate? {
        guard duration > 0, currentTime < duration else { return nil }
        currentTime = duration
        return publish()
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
        return PlayerTimeUpdate(currentTime: currentTime, duration: duration, isLive: live.isLive)
    }

    private static func normalizedInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultInterval }
        return Swift.min(Swift.max(seconds, intervalRange.lowerBound), intervalRange.upperBound)
    }

    private static func normalizedDuration(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 0
    }
}
