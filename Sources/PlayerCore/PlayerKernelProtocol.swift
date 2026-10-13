public protocol PlayerKernelProtocol: Sendable {
    init()

    func load(_ resource: PlayerResource) async throws
    func play() async
    func pause() async
    func stop() async
    func seek(to seconds: Double) async
    func events() async -> AsyncStream<PlayerKernelEvent>
    func snapshot() async -> PlayerKernelSnapshot
}
