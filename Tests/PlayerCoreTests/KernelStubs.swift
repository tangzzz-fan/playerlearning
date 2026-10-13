import Foundation
@testable import PlayerCore

enum StubTagA {}
enum StubTagB {}
enum StubTagC {}

actor KernelStub<Tag>: PlayerKernelProtocol {
    init() {}

    func load(_ resource: PlayerResource) async throws {}

    func play() async {}

    func pause() async {}

    func stop() async {}

    func seek(to seconds: Double) async {}

    func events() async -> AsyncStream<PlayerKernelEvent> {
        AsyncStream { _ in }
    }

    func snapshot() async -> PlayerKernelSnapshot {
        PlayerKernelSnapshot()
    }
}
