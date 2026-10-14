import PlayerCore
import SwiftUI

/// 控制层。**只负责"画出来 + 把用户动作转成回调"**，不持有播放状态
/// （状态在 `PlayerViewModel`）—— 这样它天生可预览、可单测。
///
/// 五件套：① 播放/暂停 ② 时间显示 ③ 进度条 + 拖拽 ④ 全屏 ⑤ 字幕菜单；
/// 外加"打开文件 / 打开字幕"两个入口。
public struct PlayerControlBar: View {
    private let isPlaying: Bool
    private let displayTime: Double
    private let duration: Double
    private let progress: Double
    private let canScrub: Bool
    private let isFullscreen: Bool

    private let subtitleLabel: String
    private let isSubtitleDisplaying: Bool
    private let subtitleTracks: [SubtitleTrack]
    private let selectedSubtitleTrackID: Int64?
    private let subtitleDelay: Double

    private let onTogglePlay: () -> Void
    private let onScrubBegan: () -> Void
    private let onScrubChanged: (Double) -> Void
    private let onScrubEnded: () -> Void
    private let onToggleFullscreen: () -> Void
    private let onToggleSubtitles: () -> Void
    private let onSelectSubtitle: (Int64?) -> Void
    private let onAdjustSubtitleDelay: (Double) -> Void
    private let onOpenFile: () -> Void
    private let onOpenSubtitle: () -> Void

    /// 延迟按钮的步长。0.1 s 太细（点 20 次才差 2 秒），0.5 s 一步刚好够顿挫感。
    public static let subtitleDelayStep = 0.5

    public init(
        isPlaying: Bool,
        displayTime: Double,
        duration: Double,
        progress: Double,
        canScrub: Bool,
        isFullscreen: Bool,
        subtitleLabel: String,
        isSubtitleDisplaying: Bool,
        subtitleTracks: [SubtitleTrack],
        selectedSubtitleTrackID: Int64?,
        subtitleDelay: Double,
        onTogglePlay: @escaping () -> Void,
        onScrubBegan: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnded: @escaping () -> Void,
        onToggleFullscreen: @escaping () -> Void,
        onToggleSubtitles: @escaping () -> Void,
        onSelectSubtitle: @escaping (Int64?) -> Void,
        onAdjustSubtitleDelay: @escaping (Double) -> Void,
        onOpenFile: @escaping () -> Void,
        onOpenSubtitle: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.displayTime = displayTime
        self.duration = duration
        self.progress = progress
        self.canScrub = canScrub
        self.isFullscreen = isFullscreen
        self.subtitleLabel = subtitleLabel
        self.isSubtitleDisplaying = isSubtitleDisplaying
        self.subtitleTracks = subtitleTracks
        self.selectedSubtitleTrackID = selectedSubtitleTrackID
        self.subtitleDelay = subtitleDelay
        self.onTogglePlay = onTogglePlay
        self.onScrubBegan = onScrubBegan
        self.onScrubChanged = onScrubChanged
        self.onScrubEnded = onScrubEnded
        self.onToggleFullscreen = onToggleFullscreen
        self.onToggleSubtitles = onToggleSubtitles
        self.onSelectSubtitle = onSelectSubtitle
        self.onAdjustSubtitleDelay = onAdjustSubtitleDelay
        self.onOpenFile = onOpenFile
        self.onOpenSubtitle = onOpenSubtitle
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

                Button(action: onOpenFile) {
                    Image(systemName: "folder")
                }
                .accessibilityIdentifier("player.openFile")

                subtitleMenu

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

    /// 字幕菜单：**开关 · 轨道选择 · 延迟调节** 三件事收在一处。
    private var subtitleMenu: some View {
        Menu {
            Button(subtitleLabel) { onToggleSubtitles() }

            if !subtitleTracks.isEmpty {
                Divider()
                ForEach(subtitleTracks) { track in
                    Button {
                        onSelectSubtitle(track.id)
                    } label: {
                        // 选中项用系统勾选标记 —— 比"文字前加 ★"更符合平台习惯。
                        if track.id == selectedSubtitleTrackID {
                            Label(track.label, systemImage: "checkmark")
                        } else {
                            Text(track.label)
                        }
                    }
                }
                Button("不显示字幕轨") { onSelectSubtitle(nil) }
            }

            Divider()
            Button("字幕延迟 −\(Self.delayText(Self.subtitleDelayStep))") {
                onAdjustSubtitleDelay(-Self.subtitleDelayStep)
            }
            Button("字幕延迟 +\(Self.delayText(Self.subtitleDelayStep))") {
                onAdjustSubtitleDelay(Self.subtitleDelayStep)
            }
            Button("延迟归零（当前 \(Self.delayText(subtitleDelay))）") {
                onAdjustSubtitleDelay(-subtitleDelay)
            }

            Divider()
            Button("载入字幕文件…") { onOpenSubtitle() }
        } label: {
            Image(systemName: isSubtitleDisplaying ? "captions.bubble.fill" : "captions.bubble")
        }
        .accessibilityIdentifier("player.subtitles")
        // 菜单的**可读标签**要如实说出状态，不能只画一个图标糊过去。
        .accessibilityLabel(subtitleLabel)
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

    /// 延迟的显示：带符号一位小数。`+0.5 s` / `-0.5 s` / `+0.0 s`。
    public static func delayText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "+0.0 s" }
        return String(format: "%+.1f s", seconds)
    }
}
