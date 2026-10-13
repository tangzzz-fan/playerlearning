#if canImport(Libmpv)
import Foundation
import PlayerCore
import Testing

@testable import PlayerMPV

/// 事件收集器。
///
/// `AsyncStream` **只能有一个消费者**，两个 `for await` 会互相抢事件（`P-014`）——
/// 所以这里由**一个**收集任务独占消费，测试侧只读快照。
actor EventLog {
    private var events: [PlayerKernelEvent] = []

    func append(_ event: PlayerKernelEvent) {
        events.append(event)
    }

    func snapshot() -> [PlayerKernelEvent] {
        events
    }

    func contains(where predicate: @Sendable (PlayerKernelEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }

    func states() -> [PlayerState] {
        events.compactMap { event in
            if case let .stateChanged(state) = event { return state }
            return nil
        }
    }
}

enum TimeoutError: Error {
    case timedOut
}

/// 轮询等待 —— **有上限**，因此失败永远表现为失败，而不是挂死（`P-014` 的教训）。
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(15),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TimeoutError.timedOut
}

/// 一个内核 + 它的独占收集任务。`shutdown()` 负责收尾，避免测试之间互相污染。
struct KernelHarness {
    let kernel: MPVKernel
    let log: EventLog
    private let pump: Task<Void, Never>

    init(windowEmbedHandle: Int64? = nil) async {
        kernel = if let windowEmbedHandle {
            MPVKernel(windowEmbedHandle: windowEmbedHandle)
        } else {
            MPVKernel()
        }
        let log = EventLog()
        self.log = log
        let stream = await kernel.events()
        pump = Task {
            for await event in stream {
                await log.append(event)
            }
        }
    }

    func events() async -> [PlayerKernelEvent] {
        await log.snapshot()
    }

    func states() async -> [PlayerState] {
        await log.states()
    }

    func waitFor(_ description: String, _ predicate: @Sendable @escaping (PlayerKernelEvent) -> Bool) async throws {
        try await waitUntil(description) { await log.contains(where: predicate) }
    }

    func shutdown() async {
        await kernel.finishEvents()
        _ = await pump.value
    }
}

/// ⚠️ `@Suite(.serialized)`：Swift Testing **默认并行**，而每个用例都会拉起一个真实的 mpv 实例
/// （视频解码 + VideoToolbox）。串行跑是为了让失败可归因 —— 并行下无法区分"实现坏了"与"互相抢资源"。
@Suite(.serialized)
struct MPVKernelTests {
    @Test
    func testLoadReachesReadyToPlayAndPlaying() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))

        try await harness.waitFor("出现 .readyToPlay") { event in
            event == .stateChanged(.readyToPlay)
        }
        try await harness.waitFor("出现 .playing（由 observe `pause` 驱动）") { event in
            event == .stateChanged(.playing)
        }

        let states = await harness.states()
        #expect(states.first == .preparing, ".preparing 必须乐观上报（它没有可观测属性）")
        #expect(
            states.contains(.readyToPlay) && states.contains(.playing),
            "实际状态序列：\(states)"
        )
        await harness.shutdown()
    }

    @Test
    func testVideoSizeIsReportedAfterLoad() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))

        let expected = CGSize(width: Double(TestClip.width), height: Double(TestClip.height))
        try await harness.waitFor("上报 \(Int(expected.width))×\(Int(expected.height))") { event in
            event == .videoSizeChanged(expected)
        }

        let snapshot = await harness.kernel.snapshot()
        #expect(
            snapshot.naturalSize == expected,
            "snapshot.naturalSize 应已写入（P2-T4 的跨层贯穿在这里被真正验证）"
        )
        await harness.shutdown()
    }

    @Test
    func testDurationIsReported() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))

        try await waitUntil("上报时长") {
            let snapshot = await harness.kernel.snapshot()
            return snapshot.duration > 0
        }

        let snapshot = await harness.kernel.snapshot()
        #expect(
            abs(snapshot.duration - TestClip.duration) < 0.5,
            "素材时长 \(TestClip.duration) s，实测 \(snapshot.duration) s"
        )
        await harness.shutdown()
    }

    @Test
    func testPlayingThenPauseIsReportedFromKernel() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("先进入 .playing") { event in
            event == .stateChanged(.playing)
        }

        await harness.kernel.pause()

        try await harness.waitFor("出现 .paused") { event in
            event == .stateChanged(.paused)
        }
        let snapshot = await harness.kernel.snapshot()
        #expect(snapshot.state == .paused, "pause 的状态必须来自 mpv 回执，而不是乐观上报（P2-T5）")
        await harness.shutdown()
    }

    @Test
    func testStopReturnsToIdle() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("先进入 .playing") { event in
            event == .stateChanged(.playing)
        }

        await harness.kernel.stop()

        try await harness.waitFor("出现 .idle") { event in
            event == .stateChanged(.idle)
        }
        let snapshot = await harness.kernel.snapshot()
        #expect(snapshot.state == .idle)
        await harness.shutdown()
    }

    /// **`P2-T6` 的运行层回归网**：坏文件必须走到 `.failed`，而不是永远停在 `.preparing`。
    /// 这条也是 `PlaybackEndReason+MPV` 的翻译层唯一的运行期证明 —— 纯逻辑已在根包被单测覆盖，
    /// 但"C 常量真的翻对了"只有这里能证。
    @Test
    func testLoadingMissingFileReportsFailure() async throws {
        let harness = await KernelHarness()
        let missing = URL(fileURLWithPath: "/nonexistent/playerlearning-missing.mkv")

        try? await harness.kernel.load(PlayerResource(url: missing))

        try await harness.waitFor("出现 .failed") { event in
            event == .stateChanged(.failed)
        }
        let snapshot = await harness.kernel.snapshot()
        #expect(snapshot.state == .failed, "实际状态：\(snapshot.state)")
        await harness.shutdown()
    }

    /// 无画面构造（`init()`）必须与有句柄构造（`init(windowEmbedHandle:)`）等价地跑通链路 ——
    /// `P2-T7` 把"晚一步 attach"的时序隐患删掉之后，两条构造口都应可用。
    @Test
    func testHeadlessConstructionStillPlays() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))

        try await harness.waitFor("headless 也要能出状态") { event in
            event == .stateChanged(.readyToPlay)
        }
        await harness.shutdown()
    }
}
#endif
