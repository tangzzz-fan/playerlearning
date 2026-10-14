import PlayerCore
import SwiftUI
import UniformTypeIdentifiers

/// 播放器整屏：**画面 + 浮在上面的控制层**。
///
/// 它不认识任何内核 —— 内核与表面句柄由 App 层装配（见 `PlayerViewModel` 的说明）。
///
/// ## 为什么控制层是 overlay 而不是"画面下面的一行"
/// 早先的写法是 `VStack { 画面; 控制条 }`，那是**错的**，有两处硬伤：
/// ① 控制层一走（自动隐藏），底部就留一条空白 —— 画面永远拿不到整屏；
/// ② 全屏时画面本该铺满，`VStack` 却把它压到 3/4 高度。
/// overlay 是唯一能同时做到"铺满 + 让开"的布局。
///
/// ## 点击
/// 点画面任意位置（含 letterbox 黑边）= 显示/隐藏控制层，**立即响应、不延迟**。
/// 手势层刻意放在控制层**下面**：这样控制层上的按钮永远优先拿到点击，不会被吃掉。
public struct PlayerScreenView: View {
    @State private var model: PlayerViewModel
    @State private var isPickingFile = false
    @State private var isPickingSubtitle = false
    @State private var autoHideTask: Task<Void, Never>?
    private let surface: WindowEmbedOutput

    /// ⚠️ surface **由外部传入**，不在内部创建：`wid` 句柄必须早于内核构造，
    /// 所以"建表面 → 建内核 → 建控制器"这个顺序必须留在 App 层看得见，
    /// 不能被一行 `PlayerScreenView(model:)` 藏起来。
    public init(model: PlayerViewModel, surface: WindowEmbedOutput) {
        _model = State(initialValue: model)
        self.surface = surface
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .ignoresSafeArea()

            PlayerSurfaceView(output: surface)
                .aspectRatio(model.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("player.surface")

            // 手势层：**铺满整块**（含画面外的黑边），位于控制层之下。
            // 只盖住"画面"那块是不够的 —— 上下黑边同样是用户会点的区域。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.toggleChrome() }
                .accessibilityIdentifier("player.tapArea")

            if model.chrome.isVisible {
                chromeOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.chrome.isVisible)
        .background(.black)
        // 全屏时连安全区一起接管（否则刘海两侧会留黑边，看起来"没全"）。
        .ignoresSafeArea(edges: model.fullscreen.hidesHostChrome ? .all : [])
        .task {
            await model.start()
            scheduleAutoHide()
        }
        .onDisappear {
            autoHideTask?.cancel()
            autoHideTask = nil
            Task { await model.teardown() }
        }
        // 播放状态一变就重排计时：开始播 ⇒ 到点收起；暂停 ⇒ `chrome` 已被模型显示出来。
        .onChange(of: model.isPlaying) { _, _ in scheduleAutoHide() }
        // ⚠️ 显隐变化也必须重排：否则"点一下把它调出来"之后**没有任何计时器在跑**
        //    —— 它会一直挂着挡画面，而这正是控制层该让开的场景。
        .onChange(of: model.chrome.isVisible) { _, _ in scheduleAutoHide() }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.movie, .video, .audiovisualContent]
        ) { result in
            guard case let .success(url) = result else { return }
            Task { await model.load(PlayerResource(url: url)) }
        }
        .fileImporter(
            isPresented: $isPickingSubtitle,
            allowedContentTypes: SubtitleLoader.allowedContentTypes
        ) { result in
            guard case let .success(url) = result else { return }
            Task { await model.loadSubtitle(from: url) }
        }
    }

    /// 控制层浮层：诊断行（上）+ 控制条（下）。
    ///
    /// 诊断行存在的理由是**可验证性** —— 手动跑一遍时靠这些可读文本判断"现在到底是什么状态"，
    /// 而不是靠截图猜。它跟着控制层一起显隐：常驻会挡画面，而它本来也不是给用户看的。
    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            statusLine
            Spacer(minLength: 0)
            PlayerControlBar(
                isPlaying: model.isPlaying,
                displayTime: model.displayTime,
                duration: model.duration,
                progress: model.displayProgress,
                canScrub: model.canScrub,
                canControl: model.canPlay,
                isFullscreen: model.fullscreen.hidesHostChrome,
                subtitleLabel: model.subtitles.label,
                isSubtitleDisplaying: model.subtitles.isDisplaying,
                subtitleTracks: model.subtitles.tracks,
                selectedSubtitleTrackID: model.subtitles.selectedTrackID,
                subtitleDelay: model.subtitles.delay,
                onTogglePlay: { Task { await model.togglePlayPause() } },
                onScrubBegan: { model.beginScrub() },
                onScrubChanged: { model.updateScrub(fraction: $0) },
                onScrubEnded: { model.endScrub() },
                onToggleFullscreen: { model.toggleFullscreen() },
                onToggleSubtitles: { Task { await model.toggleSubtitles() } },
                onSelectSubtitle: { id in Task { await model.selectSubtitleTrack(id: id) } },
                onAdjustSubtitleDelay: { delta in Task { await model.adjustSubtitleDelay(by: delta) } },
                onOpenFile: { isPickingFile = true },
                onOpenSubtitle: { isPickingSubtitle = true }
            )
        }
        // 浮层本身不该吃掉画面区域的点击 —— 只有它内部的按钮该吃。
        .allowsHitTesting(true)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.caption.monospaced())
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .accessibilityIdentifier("player.status")
    }

    private var statusText: String {
        if let failure = model.loadFailure {
            return "加载失败：\(failure)"
        }
        // 还没加载过文件时，最该告诉用户的**不是"状态是 idle"，而是"为什么按钮按不动"**。
        // 这一行直接对应"点了播放没反应"的观感：内核还没建句柄，所有控制命令都是静默 return。
        if !model.hasLoadedResource {
            return "未加载文件 · 点右侧文件夹图标选视频"
        }
        let size = model.naturalSize
        let video = size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : "—"
        let audio = model.audio.isOutputting ? "输出 \(model.audio.outputSampleRate) Hz" : "无输出"
        var text = "\(model.state) · 画面 \(video) · 音频 \(audio) · \(model.subtitles.label)"
        if let note = model.subtitleNote { text += " · \(note)" }
        if model.isBuffering { text += " · 缓冲中" }
        return text
    }

    /// 重排自动隐藏计时。
    ///
    /// ⚠️ 只在**真能隐藏**时才排队（`autoHideChrome()` 会回答这件事）——
    /// 否则暂停状态下会每秒空转一个永远不生效的计时器。
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        guard model.chrome.shouldAutoHide(isPlaying: model.isPlaying) else { return }
        let interval = model.chrome.autoHideInterval
        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await MainActor.run { _ = model.autoHideChrome() }
        }
    }
}
