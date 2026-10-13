public actor PlayerController {
    private let kernel: any PlayerKernelProtocol
    private var machine: PlayerStateMachine
    private var time: PlayerTimeModel
    private var isBuffering = false
    private var continuation: AsyncStream<PlayerControllerUpdate>.Continuation?
    private var pump: Task<Void, Never>?

    public init(kernel: any PlayerKernelProtocol, timeInterval: Double = PlayerTimeModel.defaultInterval) {
        self.kernel = kernel
        machine = PlayerStateMachine()
        time = PlayerTimeModel(interval: timeInterval)
    }

    /// 建立更新流并开始消费内核事件。重复调用会结束上一条流（避免旧消费者永久挂死）。
    @discardableResult
    public func start() async -> AsyncStream<PlayerControllerUpdate> {
        endUpdates()

        let (stream, continuation) = AsyncStream<PlayerControllerUpdate>.makeStream()
        self.continuation = continuation

        let events = await kernel.events()
        pump = Task { [weak self] in
            for await event in events {
                await self?.consume(event)
            }
            await self?.endUpdates()
        }
        return stream
    }

    public func snapshot() -> PlayerControllerSnapshot {
        PlayerControllerSnapshot(
            state: machine.state,
            currentTime: time.currentTime,
            duration: time.duration,
            isBuffering: isBuffering
        )
    }

    public func load(_ resource: PlayerResource) async throws {
        try await kernel.load(resource)
    }

    public func play() async {
        await kernel.play()
    }

    public func pause() async {
        await kernel.pause()
    }

    public func stop() async {
        await kernel.stop()
    }

    public func seek(to seconds: Double) async {
        await kernel.seek(to: time.clampSeekTarget(seconds))
    }

    public func finishUpdates() {
        endUpdates()
    }

    private func consume(_ event: PlayerKernelEvent) {
        switch event {
        case .stateChanged(let newState):
            guard machine.transition(to: newState) == .applied else { return }
            continuation?.yield(.stateChanged(newState))
        case .currentTimeChanged, .durationChanged:
            guard let update = time.apply(event) else { return }
            continuation?.yield(.timeChanged(update))
        case .bufferingChanged(let flag):
            guard flag != isBuffering else { return }
            isBuffering = flag
            continuation?.yield(.bufferingChanged(flag))
        }
    }

    private func endUpdates() {
        pump?.cancel()
        continuation?.finish()
        continuation = nil
        pump = nil
    }
}
