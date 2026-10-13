import PlayerCore
import SwiftUI

public struct PlayerRootView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "PlayerStack",
                systemImage: "play.rectangle",
                description: Text("骨架阶段：内核接入在 Phase 2。")
            )
            .navigationTitle("PlayerStack")
        }
    }
}
