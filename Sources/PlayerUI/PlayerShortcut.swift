import Foundation

/// 一条快捷键要表达的**意图**（与平台、与具体键位都无关）。
public enum PlayerShortcutCommand: Sendable, Equatable, CaseIterable {
    case togglePlayPause
    case stop
    case skipBackward
    case skipForward
    case toggleFullscreen
    /// **退出全屏**。与 `toggleFullscreen` 分开是刻意的：
    /// 它的触发条件是**条件性**的（`Esc` 只在全屏时才算数），合成一条就表达不了那个条件。
    case exitFullscreen
}

/// 与键盘布局无关的**语义键**。
///
/// 刻意**不用** SwiftUI 的 `KeyEquivalent`：这一层是纯逻辑（与 `PlayerChromeModel` /
/// `PlayerScrubModel` 同族，只依赖 Foundation），而"哪个物理键翻成哪个语义"属于翻译层的事。
/// 混在一起，「按 Esc 该不该吞键」这条规则就得在真实窗口里才验得了 —— 而它恰恰是最该被单测钉住的一条。
public enum PlayerShortcutKey: Sendable, Equatable {
    case space
    case leftArrow
    case rightArrow
    case escape
    case character(Character)
}

/// 键位 → 意图的**唯一判定处**（纯函数）。
public enum PlayerShortcuts {
    /// 跳转步长。与 `PlayerControlBar` 的 ±10 s 按钮、Demo 的 ±10 s 按钮**是同一个数** ——
    /// 键盘和按钮必须是同一种"一格"，否则用户会以为自己按错了。
    public static let skipStep: Double = 10

    /// 判定。返回 `nil` = **这个键不该被播放器吃掉**（原样交给宿主）。
    ///
    /// ⚠️ `Esc` 是这里唯一**条件性**的映射：**只在全屏时**才认。
    /// 非全屏时返回 `nil` ⇒ 宿主（macOS 窗口、就近的 sheet、导航栈）还能拿它去"返回"。
    /// 一个"什么都不该发生"的按键被播放器吞掉，是最烦人的那类交互缺陷 ——
    /// 用户按了 Esc、窗口该关没关，他会以为界面卡了。
    public static func command(
        for key: PlayerShortcutKey,
        isFullscreen: Bool
    ) -> PlayerShortcutCommand? {
        switch key {
        case .space:
            return .togglePlayPause
        case .leftArrow:
            return .skipBackward
        case .rightArrow:
            return .skipForward
        case .escape:
            return isFullscreen ? .exitFullscreen : nil
        case .character(let character):
            // ⚠️ `lowercased()` 是**字符串**操作，而 `Character.init(_:)` 要求**恰好一个**
            // 字符 —— 有些字符小写之后会变长（如 `İ`），直接构造会崩。
            // 这里的 `count == 1` 不是防御性冗余，是这条转换的**正确性前提**。
            let lowered = String(character).lowercased()
            guard lowered.count == 1, let first = lowered.first else { return nil }
            // 字母键**大小写都认**：在用户心里 Shift+K 与 K 是同一个键。
            // 不接受"按住 Shift 快捷键就失灵"。
            switch first {
            case "k": return .togglePlayPause
            case "j": return .skipBackward
            case "l": return .skipForward
            case "f": return .toggleFullscreen
            case "s": return .stop
            default: return nil
            }
        }
    }
}
