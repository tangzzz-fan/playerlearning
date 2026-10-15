import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// 「全屏」在**宿主**上的落地 —— **平台差异只在这一个文件里**。
///
/// 分开的理由：`PlayerFullscreenModel` 是**策略**（纯逻辑、可测），
/// 而"怎么让窗口/状态栏真的让位"是**平台翻译**。
/// 混在一起，策略就没法在另一平台上被单测钉住了（`P7-T2` 的收口点就是这个）。
struct PlayerHostFullscreen: ViewModifier {
    let isFullscreen: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        // macOS：全屏是**窗口**的事 —— 交给 AppKit，别在 SwiftUI 里假装接管。
        content.onChange(of: isFullscreen) { _, value in
            PlayerMacOSWindow.applyFullscreen(value)
        }
        #else
        // iOS：没有"独立窗口"这回事。全屏 = ①安全区已在 `PlayerScreenView` 里接管
        // ②状态栏与 home 指示条一起让位。旋转交给宿主 Info.plist（Demo 四个方向都允许）。
        content
            .statusBarHidden(isFullscreen)
            .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        #endif
    }
}

#if os(macOS)

/// 把"要不要全屏"落到 **macOS 窗口**上。
///
/// ⚠️ `NSWindow.toggleFullScreen` 是**切换**语义，而模型给的是**状态**。
/// 直接对着状态反复调它，会在进入/退出的动画中途把窗口卡在半屏 ——
/// 所以这里**先比对再调**（幂等）。这条比对还有一个副作用是好的：
/// 用户自己在窗口左上角点绿灯、或按 ⌃⌘F 进全屏时，我们**不会去"纠正"他**。
@MainActor
enum PlayerMacOSWindow {
    static func applyFullscreen(_ isFullscreen: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        guard window.styleMask.contains(.fullScreen) != isFullscreen else { return }
        window.toggleFullScreen(nil)
    }
}

#endif
