import SwiftUI

@main
struct PlayerStackDemoApp: App {
    var body: some Scene {
        WindowGroup {
            // Phase 2 的端到端样板：真 libmpv + 真界面。
            // `PlayerUI.PlayerRootView` 仍是 Phase 3 的外壳占位，暂时不上屏。
            NavigationStack {
                MPVDemoView()
            }
        }
        #if os(macOS)
        // 平台差异：macOS 的 `WindowGroup` 不给尺寸时会开一个很小的默认窗口，
        // 播放器在小窗口里缩成一团（且 `PlayerScreenView` 是按宽高比铺满的 ⇒ 越小越看不出画质）。
        // iOS 上窗口尺寸由系统决定，这个修饰符没有意义。
        .defaultSize(width: 960, height: 600)
        #endif
    }
}
