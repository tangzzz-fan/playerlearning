import PlayerCore
import SwiftUI

/// 控制层。**只负责"画出来 + 把用户动作转成回调"**，不持有播放状态
/// （状态在 `PlayerViewModel`）—— 这样它天生可预览、可单测。
///
/// 五件套：① 播放/暂停 ② 时间显示 ③ 进度条 + 拖拽 ④ 全屏 ⑤ 字幕菜单；
/// 外加"打开文件 / 打开字幕"两个入口。
///
/// ## 触摸区域是这一层最重要的约束
/// 它浮在**视频画面上**，而视频不是静态背景 —— 用户会在半途伸手去点。
/// 因此每个可点元素一律 44×44（Apple HIG 的最小触摸目标）**并显式 `contentShape`**：
/// 早先三个图标按钮（打开文件 / 字幕 / 全屏）只有 SF Symbol 字形本身那么大可点，
/// 边缘与图标之间的空隙全点不到 —— 这不是"手感差一点"，是**点十次漏三次**。
public struct PlayerControlBar: View {
    /// 最小触摸目标。多处复用同一个常量，避免各自写各自的数字。
    public static let minimumTouchTarget: CGFloat = 44

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
        VStack(spacing: 2) {
            PlayerSlider(
                progress: progress,
                isEnabled: canScrub,
                onScrubBegan: onScrubBegan,
                onScrubChanged: onScrubChanged,
                onScrubEnded: onScrubEnded
            )
            .padding(.horizontal, 12)

            HStack(spacing: 4) {
                iconButton("playPause", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                    onTogglePlay()
                }

                Text(Self.clock(displayTime))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("player.currentTime")

                Text("/")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))

                Text(Self.clock(duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("player.duration")

                Spacer(minLength: 4)

                iconButton("openFile", systemImage: "folder") { onOpenFile() }

                subtitleMenu

                iconButton(
                    "fullscreen",
                    systemImage: isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) { onToggleFullscreen() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        // 浮在视频上 ⇒ 必须自己保证可读性：底部渐变把画面压暗，文字用白色。
        // （用 `.thinMaterial` 会把视频糊成一块毛玻璃，反而更难看。）
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// 统一的图标按钮：**44×44 + contentShape**。
    ///
    /// 这两个缺一不可：`frame` 给足面积，`contentShape` 把**整个方形**都算作可点
    /// —— 只写 `frame` 时，SwiftUI 仍按图形的**不透明像素**判定命中，
    /// 图标四个角的空白照样点不到。
    private func iconButton(
        _ identifier: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: Self.minimumTouchTarget, height: Self.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("player.\(identifier)")
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
                .font(.body)
                .frame(width: Self.minimumTouchTarget, height: Self.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
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
