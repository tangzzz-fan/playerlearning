import Testing

@testable import PlayerCore

/// `PlayerState.pauseDescribesPlayback`（`P6-T4`）：
/// **哪些状态下的 `pause` 取值可以被解读成"在播 / 在暂停"。**
///
/// 这条规则是内核汇报状态的一道闸门。它错了的表现不是崩溃，而是
/// "内核说了一句自己支持不了的话" —— 而那种话**没有任何地方会报错**。
@Suite
struct PlayerStateTests {
    /// 有打开的文件、且它正在被播/被暂停 ⇒ `pause` 描述的就是它。
    @Test
    func testStatesWithAPlayableFileDescribePlayback() {
        #expect(PlayerState.readyToPlay.pauseDescribesPlayback)
        #expect(PlayerState.playing.pauseDescribesPlayback)
        #expect(PlayerState.paused.pauseDescribesPlayback)
    }

    /// 其余四个状态都**没有**"正在播的东西"可以让 `pause` 去描述。
    @Test
    func testStatesWithoutAPlayableFileDoNotDescribePlayback() {
        #expect(!PlayerState.idle.pauseDescribesPlayback, "停止之后没有任何东西在播")
        #expect(!PlayerState.preparing.pauseDescribesPlayback, "文件还没打开完")
        #expect(!PlayerState.finished.pauseDescribesPlayback, "播完了")
        #expect(!PlayerState.failed.pauseDescribesPlayback, "打不开")
    }

    /// `.readyToPlay` 必须是"算数"的 —— 起播正是靠它：
    /// `FILE_LOADED` → 报 `.readyToPlay` → 读 `pause` → 报 `.playing`。
    /// 少了这一条，**谁也报不出 `.playing`**（这条边是起播的唯一通路）。
    @Test
    func testReadyToPlayIsTheOnlyWayToAnnouncePlayingAtStartup() {
        #expect(PlayerState.readyToPlay.pauseDescribesPlayback)
        // 反过来盯住：`.preparing` 若也算数，起播延迟就会"变成" 2 ms（实测过的假数字）。
        #expect(!PlayerState.preparing.pauseDescribesPlayback)
    }

    /// 枚举被穷尽覆盖 —— 将来新增状态时，这条会**红**，逼人来做一次判断
    /// 而不是让新状态默默落进 `default` 分支。
    @Test
    func testEveryStateIsClassified() {
        let all: [PlayerState] = [.idle, .preparing, .readyToPlay, .playing, .paused, .finished, .failed]
        let describing = all.filter(\.pauseDescribesPlayback)
        #expect(all.count == 7, "状态新增了 —— 请在 pauseDescribesPlayback 里给它一个明确的判断")
        #expect(describing.count == 3, "实际：\(describing)")
    }
}
