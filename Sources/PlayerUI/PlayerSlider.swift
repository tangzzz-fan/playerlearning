import SwiftUI

/// 进度条。只负责"画 + 把动作转成回调"，状态与策略在 `PlayerViewModel` / `PlayerScrubModel`。
public struct PlayerSlider: View {
    private let progress: Double
    private let isEnabled: Bool
    private let onBegan: () -> Void
    private let onChanged: (Double) -> Void
    private let onEnded: () -> Void

    public init(
        progress: Double,
        isEnabled: Bool,
        onScrubBegan: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnded: @escaping () -> Void
    ) {
        self.progress = progress
        self.isEnabled = isEnabled
        onBegan = onScrubBegan
        onChanged = onScrubChanged
        onEnded = onScrubEnded
    }

    public var body: some View {
        Slider(
            value: Binding(
                get: { min(max(progress, 0), 1) },
                set: { onChanged($0) }
            ),
            in: 0 ... 1,
            onEditingChanged: { editing in
                if editing {
                    onBegan()
                } else {
                    onEnded()
                }
            }
        )
        .disabled(!isEnabled)
        .accessibilityIdentifier("player.progress")
    }
}
