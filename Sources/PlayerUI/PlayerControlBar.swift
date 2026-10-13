import SwiftUI

/// 控制层。**`P3-T1` 只放 ① 播放/暂停 ② 时间显示**；
/// ③ 进度条 + 拖拽 seek 由 `P3-T2` 加进来。
///
/// 它只负责"画出来 + 把用户动作转成回调"，**不持有播放状态**
/// （那是 `PlayerViewModel` 的事）—— 这样它天生可预览、可单测。
public struct PlayerControlBar: View {
    private let isPlaying: Bool
    private let displayTime: Double
    private let duration: Double
    private let progress: Double
    private let canScrub: Bool
    private let isFullscreen: Bool
    private let subtitleLabel: String
    private let onTogglePlay: () -> Void
    private let onScrubBegan: () -> Void
    private let onScrubChanged: (Double) -> Void
    private let onScrubEnded: () -> Void
    private let onToggleFullscreen: () -> Void
    private let onToggleSubtitles: () -> Void

    public init(
        isPlaying: Bool,
        displayTime: Double,
        duration: Double,
        progress: Double,
        canScrub: Bool,
        isFullscreen: Bool,
        subtitleLabel: String,
        onTogglePlay: @escaping () -> Void,
        onScrubBegan: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnded: @escaping () -> Void,
        onToggleFullscreen: @escaping () -> Void,
        onToggleSubtitles: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.displayTime = displayTime
        self.duration = duration
        self.progress = progress
        self.canScrub = canScrub
        self.isFullscreen = isFullscreen
        self.subtitleLabel = subtitleLabel
        self.onTogglePlay = onTogglePlay
        self.onScrubBegan = onScrubBegan
        self.onScrubChanged = onScrubChanged
        self.onScrubEnded = onScrubEnded
        self.onToggleFullscreen = onToggleFullscreen
        self.onToggleSubtitles = onToggleSubtitles
    }

    public var body: some View {
        VStack(spacing: 6) {
            PlayerSlider(
                progress: progress,
                isEnabled: canScrub,
                onScrubBegan: onScrubBegan,
                onScrubChanged: onScrubChanged,
                onScrubEnded: onScrubEnded
            )
            .padding(.horizontal, 12)

            HStack(spacing: 16) {
                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("player.playPause")

                Text(Self.clock(displayTime))
                    .monospacedDigit()
                    .accessibilityIdentifier("player.currentTime")

                Spacer(minLength: 8)

                Text(Self.clock(duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("player.duration")

                Button(action: onToggleSubtitles) {
                    Image(systemName: "captions.bubble")
                    // 按钮的**可读标签**要如实区分"开着但没源"，不能只画一个图标糊过去。
                    .accessibilityLabel(subtitleLabel)
                }
                .accessibilityIdentifier("player.subtitles")

                Button(action: onToggleFullscreen) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityIdentifier("player.fullscreen")
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
