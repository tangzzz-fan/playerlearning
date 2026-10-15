import Testing
@testable import PlayerUI

/// 键位判定的**纯逻辑**测试（`P7-T2`）。
///
/// 为什么这些值得单测：它们里有两条规则**只有靠断言才守得住** ——
/// ① `Esc` 必须**条件性**地吞（非全屏时不吞）；② 字母键大小写都得认。
/// 两条都属于"在真机上偶发、事后极难归因"的类型，而这里跑一次只要几毫秒。
@Suite
struct PlayerShortcutTests {
    private func command(
        _ key: PlayerShortcutKey,
        isFullscreen: Bool = false
    ) -> PlayerShortcutCommand? {
        PlayerShortcuts.command(for: key, isFullscreen: isFullscreen)
    }

    // MARK: - 播放控制

    @Test
    func testSpaceTogglesPlayback() {
        #expect(command(.space) == .togglePlayPause)
    }

    @Test
    func testArrowsSkipInTheirOwnDirection() {
        #expect(command(.leftArrow) == .skipBackward)
        #expect(command(.rightArrow) == .skipForward, "右箭头必须是前进 —— 写反了用户会以为是卡了")
    }

    @Test
    func testStopAndFullscreenHaveTheirOwnKeys() {
        #expect(command(.character("s")) == .stop)
        #expect(command(.character("f")) == .toggleFullscreen)
    }

    /// 在用户心里 Shift+K 与 K 是同一个键 —— 不接受"按住 Shift 快捷键就失灵"。
    @Test
    func testLetterKeysAreAcceptedRegardlessOfShift() {
        #expect(command(.character("K")) == .togglePlayPause)
        #expect(command(.character("J")) == .skipBackward)
        #expect(command(.character("L")) == .skipForward)
        #expect(command(.character("F")) == .toggleFullscreen)
        #expect(command(.character("S")) == .stop)
    }

    /// ⚠️ **本票最要紧的一条**：非全屏时 `Esc` 必须**不被吞**。
    ///
    /// 播放器把一个"什么都不该发生"的按键吃掉，宿主就再也没机会处理它 ——
    /// 用户按了 Esc、窗口该关没关，会以为界面卡了。
    @Test
    func testEscapeIsOnlyCapturedWhileFullscreen() {
        #expect(command(.escape, isFullscreen: false) == nil, "非全屏时 Esc 必须原样交给宿主")
        #expect(command(.escape, isFullscreen: true) == .exitFullscreen)
    }

    /// 同一个键在不同上下文下给不同结果 —— 证明 `isFullscreen` 真的参与了判定，
    /// 而不是被某个 `switch` 分支忽略掉（变异测试最容易放过这种"参数收了不用"）。
    @Test
    func testFullscreenFlagDoesNotLeakIntoOtherKeys() {
        for key in [PlayerShortcutKey.space, .leftArrow, .rightArrow, .character("k")] {
            #expect(
                command(key, isFullscreen: false) == command(key, isFullscreen: true),
                "\(key) 的判定不该受全屏状态影响"
            )
        }
    }

    // MARK: - 不该认的键

    @Test
    func testUnrecognizedKeysAreNotSwallowed() {
        for character in [Character("q"), Character("1"), Character("中"), Character(" ")] {
            #expect(
                command(.character(character)) == nil,
                "「\(character)」不该被播放器吃掉"
            )
        }
    }

    /// `lowercased()` 之后**长度会变**的字符不能崩 —— `Character.init(_:)` 要求恰好一个字符。
    /// （这类字符在中文/土耳其语键盘上真实存在，构造失败会直接 trap。）
    @Test
    func testLowercasingDoesNotTrapOnExpandingCharacters() {
        #expect(command(.character("İ")) == nil, "小写后变两个字符 ⇒ 必须安全返回 nil，不能崩")
    }

    // MARK: - 与按钮的一致性

    /// 键盘和按钮必须是**同一种"一格"**，否则用户会以为自己按错了。
    ///
    /// ⚠️ 这个 10 是**刻意写死在这里**的：Demo 的 `−10s` / `+10s` 按钮与
    /// `PlayerControlBar` 的跳转都按这个数走，而它们各自写死、没有共享常量。
    /// 所以这条断言的角色是**变更检测器** —— 谁改了步长却漏改键盘，这里会红。
    /// （不写成"大于 0"那种恒真式：那种断言对缺陷是隐形的，`P-054` 记过。）
    @Test
    func testSkipStepMatchesTheButtons() {
        #expect(PlayerShortcuts.skipStep == 10, "键盘步长必须与 Demo/控制条的 ±10 s 对齐")
    }
}
