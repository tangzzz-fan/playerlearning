import Foundation

/// 探测窗口：由 URL 决定 `demuxer-lavf-analyzeduration` 取什么值（`P6-T4`）。
///
/// **为什么这件事要有一个"计划"而不是内核里一行 `if`**：窗口的值**不是越短越好**，
/// 它取决于**源怎么投递数据**（"短"换来的是起播快，"长"换来的是流信息看得准）：
///
/// - **实时投递的源**（RTSP / RTMP / SRT / UDP）：数据按真实时间到达 ⇒ lavf"读够 N 秒媒体"
///   直接变成**用户等 N 秒**。真机实测（同一个流、只改这一项）：
///   默认 ⇒ `file-loaded` = 1131 / 1237 / 1144 ms；设 0.2 s ⇒ **380 / 336 ms**；
///   出画 1263–1354 ms ⇒ **505–788 ms**。
/// - **按需拉取的源**（HTTP / 本地文件）：数据按网络速度一次到手，窗口长短几乎不影响等待
///   （实测 HTTP mp4 的 `file-loaded` 只有 57–81 ms），而窗口存在的意义正是
///   **让 lavf 看清流信息** ⇒ **不动它**。
///
/// 判据：**只在"窗口会变成用户等待"的那一类源上缩短它。**
/// 对拉取式的源缩短窗口，是拿一个没量到的好处去换一个没量到的风险。
struct StreamProbePlan: Equatable {
    /// 传给 `demuxer-lavf-analyzeduration` 的秒数；`nil` = **不动它**（用 mpv / lavf 的默认）。
    let analyzeduration: Double?

    /// 实时投递的协议 —— 数据按真实时间到达，窗口直接等于用户等待。
    static let realtimeSchemes: Set<String> = [
        "rtsp", "rtsps", "rtmp", "rtmps", "rtmpe", "rtmpt", "rtmpts", "srt", "udp", "rtp",
    ]

    /// 实时源上取的窗口：0.2 s ≈ 5 帧（25 fps）—— 够 lavf 看清编解码参数，又短到不构成等待。
    /// **取值依据是本票实测**，不是抄来的推荐值。
    static let realtimeAnalyzeduration = 0.2

    init(_ url: URL) {
        // ⚠️ `URL` **原样保留** scheme 的大小写（`URL(string: "RTSP://x")!.scheme == "RTSP"`），
        //    不归一化的话，写 `RTSP://` 的调用方会让这条规则**静默失效**
        //    —— 而失效的表现只是"起播慢 1 秒"，谁也不会去查这里。
        let scheme = url.scheme?.lowercased() ?? ""
        analyzeduration = Self.realtimeSchemes.contains(scheme) ? Self.realtimeAnalyzeduration : nil
    }
}
