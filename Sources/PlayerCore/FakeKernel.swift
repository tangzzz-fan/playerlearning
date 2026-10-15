import CoreGraphics
import Foundation

public actor FakeKernel: PlayerKernelProtocol {
    public private(set) var loadedResources: [PlayerResource] = []
    public private(set) var seekRequests: [Double] = []
    public private(set) var playCallCount = 0
    public private(set) var pauseCallCount = 0
    public private(set) var stopCallCount = 0
    public private(set) var addedSubtitles: [(url: URL, title: String?)] = []
    public private(set) var selectedSubtitleTrackIDs: [Int64?] = []
    public private(set) var subtitleVisibilityRequests: [Bool] = []
    public private(set) var subtitleDelayRequests: [Double] = []
    public private(set) var selectedVideoTrackIDs: [Int64] = []

    private let scriptedDuration: Double
    private let scriptedNaturalSize: CGSize
    private let scriptedLoadError: (any Error)?
    private var state: PlayerState = .idle
    private var duration: Double = 0
    private var currentTime: Double = 0
    private var isBuffering = false
    private var naturalSize: CGSize = .zero
    private var audio = PlayerAudioState()
    private var subtitles = PlayerSubtitleState()
    private var videoTracks = PlayerVideoTrackState()
    private var continuation: AsyncStream<PlayerKernelEvent>.Continuation?

    public init() {
        scriptedDuration = 0
        scriptedNaturalSize = .zero
        scriptedLoadError = nil
    }

    public init(duration: Double = 0, naturalSize: CGSize = .zero, loadError: (any Error)? = nil) {
        scriptedDuration = duration
        scriptedNaturalSize = naturalSize
        scriptedLoadError = loadError
    }

    public func load(_ resource: PlayerResource) async throws {
        emit(.stateChanged(.preparing))
        if let scriptedLoadError {
            emit(.stateChanged(.failed))
            throw scriptedLoadError
        }
        loadedResources.append(resource)
        emit(.stateChanged(.readyToPlay))
        emit(.durationChanged(scriptedDuration))
        // 尺寸未知（.zero）时**不上报** —— 真内核拿不到 width/height 时也不该报一个假尺寸。
        if scriptedNaturalSize != .zero {
            emit(.videoSizeChanged(scriptedNaturalSize))
        }
    }

    public func play() async {
        playCallCount += 1
        emit(.stateChanged(.playing))
    }

    public func pause() async {
        pauseCallCount += 1
        emit(.stateChanged(.paused))
    }

    public func stop() async {
        stopCallCount += 1
        emit(.stateChanged(.idle))
    }

    public func seek(to seconds: Double) async {
        seekRequests.append(seconds)
    }

    public func addSubtitle(url: URL, title: String?) async {
        addedSubtitles.append((url, title))
        // 真内核会枚举出新轨道并自动选中它 —— 假内核照同样语义走，
        // 否则装配层/界面在测试里看到的是一条永远不会变的字幕状态。
        let track = SubtitleTrack(id: Int64(100 + addedSubtitles.count), title: title, isExternal: true)
        subtitles.tracks.append(track)
        subtitles.selectedTrackID = track.id
        subtitles.isVisible = true
        emit(.subtitlesChanged(subtitles))
    }

    public func selectSubtitleTrack(id: Int64?) async {
        selectedSubtitleTrackIDs.append(id)
        guard subtitles.selectedTrackID != id else { return }
        subtitles.selectedTrackID = id
        emit(.subtitlesChanged(subtitles))
    }

    public func setSubtitleVisible(_ visible: Bool) async {
        subtitleVisibilityRequests.append(visible)
        guard subtitles.isVisible != visible else { return }
        subtitles.isVisible = visible
        emit(.subtitlesChanged(subtitles))
    }

    public func setSubtitleDelay(_ seconds: Double) async {
        subtitleDelayRequests.append(seconds)
        guard subtitles.delay != seconds else { return }
        subtitles.delay = seconds
        emit(.subtitlesChanged(subtitles))
    }

    /// 切清晰度。**照真内核的语义走**：记下请求、改选中项、如实上报 ——
    /// 而不是"记一笔然后什么都不发生"（那会让装配层/界面的测试永远测不到状态变化）。
    ///
    /// 档位清单由测试用 `emit(.videoTracksChanged(…))` 灌进来（真内核里它来自 `track-list`）。
    public func selectVideoTrack(id: Int64) async {
        selectedVideoTrackIDs.append(id)
        guard videoTracks.selectedTrackID != id else { return }
        videoTracks.selectedTrackID = id
        emit(.videoTracksChanged(videoTracks))
    }

    public func events() async -> AsyncStream<PlayerKernelEvent> {        let (stream, continuation) = AsyncStream<PlayerKernelEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func finishEvents() {
        continuation?.finish()
        continuation = nil
    }

    public func snapshot() async -> PlayerKernelSnapshot {
        PlayerKernelSnapshot(
            state: state,
            currentTime: currentTime,
            duration: duration,
            isBuffering: isBuffering,
            naturalSize: naturalSize,
            audio: audio,
            subtitles: subtitles,
            videoTracks: videoTracks
        )
    }

    public func emit(_ event: PlayerKernelEvent) {
        apply(event)
        _ = continuation?.yield(event)
    }

    private func apply(_ event: PlayerKernelEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
        case .currentTimeChanged(let seconds):
            currentTime = seconds
        case .durationChanged(let seconds):
            duration = seconds
        case .bufferingChanged(let flag):
            isBuffering = flag
        case .videoSizeChanged(let size):
            naturalSize = size
        case .audioChanged(let state):
            audio = state
        case .subtitlesChanged(let state):
            subtitles = state
        case .videoTracksChanged(let state):
            videoTracks = state
        }
    }
}
