/// 一次播放**结束**的原因。
///
/// 为什么单独建这个类型、而不是直接在 `MPVKernel` 里 `switch` mpv 的 `mpv_end_file_reason`：
/// 这段是**策略**（"什么原因该走到哪个状态"），而不是**翻译**（"mpv 的哪个常量对应哪个原因"）。
/// 策略放在 `PlayerCore` 才能被门禁覆盖 —— `MPV/` 包只能编译、跑不了单测，
/// 写在那边等于没有回归网（见 `docs/PITFALLS.md` `P-034`）。
/// `MPVKernel` 只负责把 C 常量翻成本枚举，那一层薄到只剩几行映射。
public enum PlaybackEndReason: Sendable, Equatable, CaseIterable {
    /// 读到文件末尾，或播放范围被限制而自然走完。**注意：不完整的文件与断掉的网络流也可能**
    /// **报这个原因**（见 mpv 头文件对 `MPV_END_FILE_REASON_EOF` 的说明）⇒ 它**不是**错误信号。
    case endOfStream
    /// 被外部动作停掉（本项目的 `stop()` 命令即走这条）。
    case stopped
    /// 播放中止且 mpv 给出了错误码。**只有这一条算失败。**
    case error
    /// 播放器被关闭。
    case quit
    /// 当前文件是播放列表，mpv 会自行接着放后续条目。
    case redirect
}

public extension PlaybackEndReason {
    /// 该原因对应的播放状态；`nil` 表示**本次结束不需要改变状态**。
    var resultingState: PlayerState? {
        switch self {
        case .endOfStream:
            .finished
        case .error:
            .failed
        case .stopped:
            .idle
        case .quit, .redirect:
            nil
        }
    }
}
