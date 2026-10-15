import SwiftUI

extension PlayerShortcutKey {
    /// `KeyEquivalent` → 语义键。**翻译层唯一要做的事**（判断在 `PlayerShortcuts` 里）。
    init(_ key: KeyEquivalent) {
        switch key {
        case .space: self = .space
        case .leftArrow: self = .leftArrow
        case .rightArrow: self = .rightArrow
        case .escape: self = .escape
        default: self = .character(key.character)
        }
    }
}

/// 把 `PlayerShortcuts` 的判定接到 SwiftUI 的按键事件上（**薄翻译，不含策略**）。
///
/// ## 为什么是 `onKeyPress` 而不是 `keyboardShortcut`
/// `keyboardShortcut` 只能挂在**按钮**上，而按钮会**随控制层一起自动隐藏** ——
/// 隐藏视图上的快捷键不响应。症状很具体：**全屏看片时按空格没反应**，
/// 而那恰恰是最需要快捷键的时刻（控制层早自动收走了）。
///
/// `onKeyPress` 挂在**常驻的根视图**上，而且能**如实返回 `.ignored`** ——
/// 这正是 `Esc` 需要的语义：非全屏时不吞键，让宿主自己去处理。
struct PlayerKeyboardShortcuts: ViewModifier {
    let isFullscreen: Bool
    let onCommand: @MainActor (PlayerShortcutCommand) -> Void

    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            // 键盘事件只送给**有焦点**的视图 ⇒ 根视图必须自己争取焦点。
            .focusable()
            // 焦点框会画在画面上（macOS 默认一圈蓝边），而这里并没有"被聚焦的控件"可言。
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onKeyPress(phases: .down) { press in
                guard let command = PlayerShortcuts.command(
                    for: PlayerShortcutKey(press.key),
                    isFullscreen: isFullscreen
                ) else {
                    // 没认出来的键**原样放走** —— 这一句就是 Esc 能被宿主接住的原因。
                    return .ignored
                }
                onCommand(command)
                return .handled
            }
    }
}
