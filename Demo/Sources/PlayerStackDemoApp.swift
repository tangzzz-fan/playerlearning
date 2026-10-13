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
    }
}
