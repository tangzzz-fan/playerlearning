import CoreGraphics

public actor FakeKernel: PlayerKernelProtocol {
    public private(set) var loadedResources: [PlayerResource] = []
    public private(set) var seekRequests: [Double] = []
    public private(set) var playCallCount = 0
    public private(set) var pauseCallCount = 0
    public private(set) var stopCallCount = 0

    private let scriptedDuration: Double
    private let scriptedNaturalSize: CGSize
    private let scriptedLoadError: (any Error)?
    private var state: PlayerState = .idle
    private var duration: Double = 0
    private var currentTime: Double = 0
    private var isBuffering = false
    private var naturalSize: CGSize = .zero
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

    public func events() async -> AsyncStream<PlayerKernelEvent> {
        let (stream, continuation) = AsyncStream<PlayerKernelEvent>.makeStream()
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
            naturalSize: naturalSize
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
        }
    }
}
