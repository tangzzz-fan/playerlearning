import SwiftUI

/// 控制层。**`P3-T1` 只放 ① 播放/暂停 ② 时间显示**；
/// ③ 进度条 + 拖拽 seek 由 `P3-T2` 加进来。
///
/// 它只负责"画出来 + 把用户动作转成回调"，**不持有播放状态**
/// （那是 `PlayerViewModel` 的事）—— 这样它天生可预览、可单测。
public struct PlayerControlBar: View {
    private let isPlaying: Bool
    private let currentTime: Double
    private let duration: Double
    private let onTogglePlay: () -> Void

    public init(
        isPlaying: Bool,
        currentTime: Double,
        duration: Double,
        onTogglePlay: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.onTogglePlay = onTogglePlay
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("player.playPause")

                Text(Self.clock(currentTime))
                    .monospacedDigit()
                    .accessibilityIdentifier("player.currentTime")

                Spacer(minLength: 8)

                Text(Self.clock(duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("player.duration")
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    /// `mm:ss`（超过一小时给 `h:mm:ss`）。负数 / 非有限值一律显示 `0:00` ——
    /// 播放器不该因为内核给了怪值就把 `-1:-30` 画出来。
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
