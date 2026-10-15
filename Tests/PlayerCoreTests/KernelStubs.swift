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

    func addSubtitle(url: URL, title: String?) async {}

    func selectSubtitleTrack(id: Int64?) async {}

    func selectVideoTrack(id: Int64) async {}

    func setSubtitleVisible(_ visible: Bool) async {}

    func setSubtitleDelay(_ seconds: Double) async {}

    func events() async -> AsyncStream<PlayerKernelEvent> {
        AsyncStream { _ in }
    }

    func snapshot() async -> PlayerKernelSnapshot {
        PlayerKernelSnapshot()
    }
}
