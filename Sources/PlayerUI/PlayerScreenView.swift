import SwiftUI

/// 播放器整屏：**画面 + 控制层**。
///
/// 它不认识任何内核 —— 内核与表面句柄由 App 层装配（见 `PlayerViewModel` 的说明）。
public struct PlayerScreenView: View {
    @State private var model: PlayerViewModel
    private let surface: WindowEmbedOutput

    /// ⚠️ surface **由外部传入**，不在内部创建：`wid` 句柄必须早于内核构造，
    /// 所以"建表面 → 建内核 → 建控制器"这个顺序必须留在 App 层看得见，
    /// 不能被一行 `PlayerScreenView(model:)` 藏起来。
    public init(model: PlayerViewModel, surface: WindowEmbedOutput) {
        _model = State(initialValue: model)
        self.surface = surface
    }

    public var body: some View {
        VStack(spacing: 0) {
            videoArea
            PlayerControlBar(
                isPlaying: model.isPlaying,
                displayTime: model.displayTime,
                duration: model.duration,
                progress: model.displayProgress,
                canScrub: model.canScrub,
                isFullscreen: model.fullscreen.hidesHostChrome,
                subtitleLabel: model.subtitles.label,
                onTogglePlay: { Task { await model.togglePlayPause() } },
                onScrubBegan: { Task { await model.beginScrub() } },
                onScrubChanged: { model.updateScrub(fraction: $0) },
                onScrubEnded: { Task { await model.endScrub() } },
                onToggleFullscreen: { model.toggleFullscreen() },
                onToggleSubtitles: { model.toggleSubtitles() }
            )
            if !model.fullscreen.hidesHostChrome {
                statusLine
            }
        }
        .background(.black)
        // 全屏时连安全区一起接管（否则刘海两侧会留黑边，看起来"没全"）。
        .ignoresSafeArea(edges: model.fullscreen.hidesHostChrome ? .all : [])
        .task { await model.start() }
        .onDisappear { Task { await model.teardown() } }
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            PlayerSurfaceView(output: surface)
        }
        .aspectRatio(model.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("player.surface")
    }

    /// 一行诊断信息。它存在的理由是**可验证性**：`G3` 的 UI 测试与端到端脚本
    /// 都靠这些可读文本判断"现在到底是什么状态"，而不是靠截图猜。
    private var statusLine: some View {
        Text(statusText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("player.status")
    }

    private var statusText: String {
        if let failure = model.loadFailure {
            return "加载失败：\(failure)"
        }
        let size = model.naturalSize
        let video = size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : "—"
        let audio = model.audio.isOutputting ? "输出 \(model.audio.outputSampleRate) Hz" : "无输出"
        return "\(model.state) · 画面 \(video) · 音频 \(audio) · \(model.subtitles.label)"
            + (model.isBuffering ? " · 缓冲中" : "")
    }
}
