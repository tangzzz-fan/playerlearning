public enum PlayerState: Sendable, Equatable {
    case idle
    case preparing
    case readyToPlay
    case playing
    case paused
    case finished
    case failed
}

public extension PlayerState {
    /// 这个状态下，mpv 的 `pause` 取值**描述的是"文件在播还是在暂停"**吗？（`P6-T4`）
    ///
    /// 为什么需要这条规则：`pause` 是个**全局属性**，mpv 会在很多与"播放"无关的时机
    /// 把它重置回 `no` —— 文件**还没打开**的时候（`.preparing`）、打不开而失败之后（`.failed`）、
    /// 停止之后（`.idle`）、播完之后（`.finished`）。把这些 `no` 当成"开始播放"，
    /// 内核就会报出一句**它无法支持的话**。
    ///
    /// 两个实测后果（真机 `[startup]` 埋点 + 内核用例）：
    /// - `.preparing` 里报 `.playing`：`load()` 之后 **2 ms** 就到，而文件要 57–1200 ms 才打开。
    /// - `.failed` 之后报 `.playing`：**把 `.failed` 盖掉**，于是"打不开的文件"终态变成"在播"。
    ///   （这条曾长期表现为"偶尔红一次、复跑又绿"，被记成了资源争抢 —— 其实是同一句话的时序。）
    ///
    /// 判据同 `P-038`：**靠下游正好把错的东西挡掉了，不叫正确。**
    /// 装配层 `PlayerStateMachine` 恰好把 `.preparing → .playing` 列为非法边，
    /// 才让它从没漏到界面上 —— 但内核自己的 `state` 与 `snapshot()` 一直是假的。
    var pauseDescribesPlayback: Bool {
        switch self {
        case .readyToPlay, .playing, .paused:
            true
        case .idle, .preparing, .finished, .failed:
            false
        }
    }
}
