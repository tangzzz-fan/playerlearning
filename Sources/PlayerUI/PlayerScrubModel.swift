/// 拖拽进度条的**策略**（纯逻辑，无 UI 依赖）。
///
/// 为什么单独建一个类型而不是把状态塞进 View：
/// 拖拽有几条**不显眼但必须对**的规则 —— 比例要钳、时长未知要归零、
/// **没在拖的时候松手不能发 seek**、松手后要知道该不该恢复播放。
/// 这些都能被单测与变异覆盖；写进 View 里就只能靠手点。
///
/// 与 `VideoSizeTracker` / `PlayerAudioState` 同一思路：**策略放得可测，View 只负责画**。
public struct PlayerScrubModel: Sendable, Equatable {
    public private(set) var isScrubbing = false
    /// 拖拽中的预览时间（不参与播放，只用来显示与松手后 seek）。
    public private(set) var previewTime: Double = 0
    /// 开始拖拽时是否正在播 —— 决定松手后要不要恢复播放。
    public private(set) var wasPlayingBeforeScrub = false

    public init() {}

    /// 按下。记录"本来在不在播"，并把预览拉到当前位置。
    public mutating func begin(currentTime: Double, isPlaying: Bool) {
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        previewTime = currentTime.isFinite ? max(0, currentTime) : 0
    }

    /// 拖动中。`fraction` 是**比例**（不是秒）：超出 `0…1` 一律钳住，
    /// 非有限值按 `0` 处理 —— 进度条不该因为内核给了怪值而跳到末尾。
    public mutating func update(fraction: Double, duration: Double) {
        guard isScrubbing else { return }
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        previewTime = duration > 0 ? clamped * duration : 0
    }

    /// 松手。返回**要 seek 的目标**；没在拖时返回 `nil`
    /// （避免"点一下就发一次 seek"，也避免重复松手发两次）。
    @discardableResult
    public mutating func end() -> Double? {
        guard isScrubbing else { return nil }
        isScrubbing = false
        wasPlayingBeforeScrub = false
        return previewTime
    }
}
