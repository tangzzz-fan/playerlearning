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
    /// 这条时间轴是不是直播。为真时**整条进度条消失**，时间位置换成 LIVE 徽标。
    ///
    /// 不是"把百分比画得保守一点"：直播的 `progress` 分母是**滑动窗口末端**，
    /// 它恒在 0.9 以上抖动（`docs/19` §4.2 实测 0.53–0.96）—— 画出来就是在骗人。
    private let isLive: Bool
    /// 播放控制是否可用（= 已经加载过文件）。
    ///
    /// 未加载时 `play()` / `pause()` / 字幕命令在内核层都是**静默 return**
    /// （连 mpv 句柄都还没建）⇒ 只有把它们**灰掉**，用户才不会以为界面坏了。
    private let canControl: Bool
    private let isFullscreen: Bool

    private let subtitleLabel: String
    private let isSubtitleDisplaying: Bool
    private let subtitleTracks: [SubtitleTrack]
    private let selectedSubtitleTrackID: Int64?
    private let subtitleDelay: Double

    /// 视频轨状态 = 界面上的「清晰度」。
    ///
    /// 传**整个状态**而不是拆成 `tracks` / `id` 两个参数：这一层需要的判断
    /// （「有没有可选项」「当前是哪一档」）都由它承担，拆开就等于把同一套规则抄两遍。
    private let videoTracks: PlayerVideoTrackState

    private let onTogglePlay: () -> Void
    private let onScrubBegan: () -> Void
    private let onScrubChanged: (Double) -> Void
    private let onScrubEnded: () -> Void
    private let onToggleFullscreen: () -> Void
    private let onToggleSubtitles: () -> Void
    private let onSelectSubtitle: (Int64?) -> Void
    private let onAdjustSubtitleDelay: (Double) -> Void
    private let onSelectVideoTrack: (Int64) -> Void
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
        canControl: Bool,
        isFullscreen: Bool,
        subtitleLabel: String,
        isSubtitleDisplaying: Bool,
        subtitleTracks: [SubtitleTrack],
        selectedSubtitleTrackID: Int64?,
        subtitleDelay: Double,
        videoTracks: PlayerVideoTrackState = PlayerVideoTrackState(),
        isLive: Bool = false,
        onTogglePlay: @escaping () -> Void,
        onScrubBegan: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnded: @escaping () -> Void,
        onToggleFullscreen: @escaping () -> Void,
        onToggleSubtitles: @escaping () -> Void,
        onSelectSubtitle: @escaping (Int64?) -> Void,
        onAdjustSubtitleDelay: @escaping (Double) -> Void,
        onSelectVideoTrack: @escaping (Int64) -> Void = { _ in },
        onOpenFile: @escaping () -> Void,
        onOpenSubtitle: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.displayTime = displayTime
        self.duration = duration
        self.progress = progress
        self.canScrub = canScrub
        self.canControl = canControl
        self.isFullscreen = isFullscreen
        self.subtitleLabel = subtitleLabel
        self.isSubtitleDisplaying = isSubtitleDisplaying
        self.subtitleTracks = subtitleTracks
        self.selectedSubtitleTrackID = selectedSubtitleTrackID
        self.subtitleDelay = subtitleDelay
        self.videoTracks = videoTracks
        self.isLive = isLive
        self.onTogglePlay = onTogglePlay
        self.onScrubBegan = onScrubBegan
        self.onScrubChanged = onScrubChanged
        self.onScrubEnded = onScrubEnded
        self.onToggleFullscreen = onToggleFullscreen
        self.onToggleSubtitles = onToggleSubtitles
        self.onSelectSubtitle = onSelectSubtitle
        self.onAdjustSubtitleDelay = onAdjustSubtitleDelay
        self.onSelectVideoTrack = onSelectVideoTrack
        self.onOpenFile = onOpenFile
        self.onOpenSubtitle = onOpenSubtitle
    }

    public var body: some View {
        VStack(spacing: 2) {
            if !isLive {
                PlayerSlider(
                    progress: progress,
                    isEnabled: canScrub,
                    onScrubBegan: onScrubBegan,
                    onScrubChanged: onScrubChanged,
                    onScrubEnded: onScrubEnded
                )
                .padding(.horizontal, 12)
            }

            HStack(spacing: 4) {
                iconButton(
                    "playPause",
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    isEnabled: canControl
                ) {
                    onTogglePlay()
                }

                if isLive {
                    liveBadge
                } else {
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
                }

                Spacer(minLength: 4)

                iconButton("openFile", systemImage: "folder") { onOpenFile() }

                videoTrackMenu

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

    /// 直播徽标：红点 + `LIVE`，占据原「当前时间 / 总时长」的位置。
    ///
    /// 红点是**这一屏唯一带颜色的元素**（其余全是白/灰）—— 直播与点播的区别
    /// 必须一眼看得出来，否则用户会去找那条不存在的进度条。
    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            Text("LIVE")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.live")
        .accessibilityLabel("直播")
    }

    /// 统一的图标按钮：**44×44 + contentShape**。
    ///
    /// 这两个缺一不可：`frame` 给足面积，`contentShape` 把**整个方形**都算作可点
    /// —— 只写 `frame` 时，SwiftUI 仍按图形的**不透明像素**判定命中，
    /// 图标四个角的空白照样点不到。
    private func iconButton(
        _ identifier: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: Self.minimumTouchTarget, height: Self.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .disabled(!isEnabled)
        // `.disabled` 在视频画面上不够明显（系统那点变灰看不出来）⇒ 再压一层透明度。
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityIdentifier("player.\(identifier)")
    }

    /// 清晰度菜单 —— **只在真的有多档时才出现**。
    ///
    /// 单码率（普通 mp4 / 单档 HLS）只有 1 条视频轨 ⇒ 菜单里只有一项，
    /// 点它也不会有任何变化 ⇒ 显示出来纯粹是噪音（`docs/14` §三 已记下这个取舍）。
    /// 所以这里是**整条隐藏**，而不是"置灰一个只有一项的菜单"。
    ///
    /// 图标选 `rectangle.ratio.16.to.9`：这个入口调的就是**画面尺寸**本身，
    /// 用齿轮 / 滑块会让人以为里面装的是设置项。
    @ViewBuilder
    private var videoTrackMenu: some View {
        if videoTracks.hasAlternatives {
            Menu {
                ForEach(videoTracks.tracks) { track in
                    Button {
                        onSelectVideoTrack(track.id)
                    } label: {
                        if track.id == videoTracks.selectedTrackID {
                            Label(track.label, systemImage: "checkmark")
                        } else {
                            Text(track.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.ratio.16.to.9")
                    .font(.body)
                    .frame(width: Self.minimumTouchTarget, height: Self.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.white)
            // 没加载文件时内核连句柄都没有，切档会静默失败 ⇒ 灰掉。
            .disabled(!canControl)
            .opacity(canControl ? 1 : 0.35)
            .accessibilityIdentifier("player.videoTracks")
            // 菜单的**可读标签**要如实说出当前档位，不能只画一个图标糊过去。
            .accessibilityLabel(canControl ? videoTracks.label : "清晰度（先打开视频）")
        }
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
        // 没有文件时没有东西可以挂字幕 —— 灰掉，而不是让用户选完发现没反应。
        .disabled(!canControl)
        .opacity(canControl ? 1 : 0.35)
        .accessibilityIdentifier("player.subtitles")
        // 菜单的**可读标签**要如实说出状态，不能只画一个图标糊过去。
        .accessibilityLabel(canControl ? subtitleLabel : "字幕（先打开视频）")
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
