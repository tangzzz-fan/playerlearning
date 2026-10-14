import SwiftUI

/// 进度条。只负责"画 + 把动作转成回调"，状态与策略在 `PlayerViewModel` / `PlayerScrubModel`。
///
/// ## 为什么不用系统 `Slider`
/// 两条实测出来的理由：
/// ① **点不准**：系统 `Slider` 主要认 thumb 附近的拖动，"点轨道跳到这里"在 iOS 上不可靠；
///    改到 `0.6` 这个位置常常要点好几次。播放器里这是最高频的动作，不能靠运气。
/// ② **看不见**：它默认的轨道在视频画面（可能很亮）上几乎不可见 —— 而这一层是**浮在视频上的**。
///
/// 自己画还顺带换来两件事：整块 **44 高**都能拖（手指不用瞄准细轨道），
/// 以及按下时 thumb 放大 —— 用户能立刻知道"我按到了"。
public struct PlayerSlider: View {
    /// 触摸高度。给足 44（系统下限）—— 它下面紧挨着播放按钮，太窄拇指会点串。
    public static let touchHeight: CGFloat = 44

    private static let trackHeight: CGFloat = 4
    private static let thumbSize: CGFloat = 14

    private let progress: Double
    private let isEnabled: Bool
    private let onBegan: () -> Void
    private let onChanged: (Double) -> Void
    private let onEnded: () -> Void

    /// 手指是否正按着（纯视觉反馈；业务上的"正在拖拽"在 `PlayerScrubModel`）。
    @State private var isPressing = false

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
        GeometryReader { geometry in
            let width = geometry.size.width
            let ratio = clamped(progress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: Self.trackHeight)

                Capsule()
                    .fill(.white)
                    .frame(width: width * ratio, height: Self.trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: Self.thumbSize, height: Self.thumbSize)
                    .scaleEffect(isPressing ? 1.45 : 1)
                    .offset(x: thumbOffset(width: width, ratio: ratio))
                    .animation(.easeOut(duration: 0.12), value: isPressing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 整块方形都算可点：否则只有轨道那 4 pt 能碰到（`contentShape` 是这一步的关键）。
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        .frame(height: Self.touchHeight)
        // 时长未知时压暗 —— 不画成灰的，那在视频画面上看不出来。
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier("player.progress")
        .accessibilityLabel("播放进度")
        .accessibilityValue(Text("\(Int(clamped(progress) * 100))%"))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment:
                onBegan()
                onChanged(min(1, clamped(progress) + 0.05))
                onEnded()
            case .decrement:
                onBegan()
                onChanged(max(0, clamped(progress) - 0.05))
                onEnded()
            @unknown default:
                break
            }
        }
    }

    /// `minimumDistance: 0` 是"点哪跳哪"的关键：默认的 `DragGesture` 要移动一小段才触发，
    /// 于是"点一下"什么都不会发生 —— 那正是用户说的"点了没反应"。
    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled, width > 0 else { return }
                if !isPressing {
                    isPressing = true
                    onBegan()
                }
                onChanged(clamped(value.location.x / width))
            }
            .onEnded { _ in
                guard isPressing else { return }
                isPressing = false
                onEnded()
            }
    }

    /// 拖到轨道外面（左边/右边）时把 thumb 夹在边界内，别让它跑出容器。
    private func thumbOffset(width: CGFloat, ratio: Double) -> CGFloat {
        let raw = width * ratio - Self.thumbSize / 2
        return min(max(raw, 0), max(0, width - Self.thumbSize))
    }

    private func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
