#if canImport(Libmpv)
import Libmpv
import PlayerCore

/// mpv C 常量 → `PlaybackEndReason` 的**翻译层**。
///
/// 这里刻意只做翻译、不做决策：`什么原因该走到哪个状态` 是策略，放在 `PlayerCore`
/// 才能被门禁的单测与变异覆盖（`MPV/` 包在本机只能编译，跑不了单测，见 `P-034`）。
extension PlaybackEndReason {
    /// 认不出的原因返回 `nil` —— mpv 头文件明确要求"Unknown values should be treated as unknown"，
    /// 所以既不能猜成 `.endOfStream`（会把未知错误报成"放完了"），也不能崩。
    init?(mpvReason: mpv_end_file_reason) {
        switch mpvReason {
        case MPV_END_FILE_REASON_EOF:
            self = .endOfStream
        case MPV_END_FILE_REASON_STOP:
            self = .stopped
        case MPV_END_FILE_REASON_QUIT:
            self = .quit
        case MPV_END_FILE_REASON_ERROR:
            self = .error
        case MPV_END_FILE_REASON_REDIRECT:
            self = .redirect
        default:
            return nil
        }
    }
}
#endif
