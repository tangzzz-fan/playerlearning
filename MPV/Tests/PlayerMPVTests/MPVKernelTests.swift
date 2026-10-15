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

    func waitFor(
        _ description: String,
        timeout: Duration = .seconds(15),
        _ predicate: @Sendable @escaping (PlayerKernelEvent) -> Bool
    ) async throws {
        try await waitUntil(description, timeout: timeout) { await log.contains(where: predicate) }
    }

    func shutdown() async {
        await kernel.finishEvents()
        _ = await pump.value
    }
}

/// ⚠️ `@Suite(.serialized)`：Swift Testing **默认并行**，而每个用例都会拉起一个真实的 mpv 实例
/// （视频解码 + VideoToolbox）。串行跑是为了让失败可归因 —— 并行下无法区分"实现坏了"与"互相抢资源"。
///
/// ⚠️⚠️ **而且 `.serialized` 只管"套件内部"**：两个套件之间**仍然并行**。
/// 这条是实测踩出来的 —— 新增一个字幕套件之后，同一次改动**两次运行失败在不同的测试上**
/// （一次是字幕的、一次是既有的 `testLoadingMissingFileReportsFailure`），
/// 单独复跑两次又全绿：典型的资源争抢。
/// ⇒ **本文件里所有需要真实 mpv 的用例都必须在同一个 `@Suite(.serialized)` 内**，
///    不要再拆出第二个套件（哪怕主题不同、哪怕文件会变长）。
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
        // `.playing` 必须**晚于** `.readyToPlay`：文件打开之前没有任何东西在播（见 `P6-T4`）。
        let ready = try #require(states.firstIndex(of: .readyToPlay))
        let playing = try #require(states.firstIndex(of: .playing))
        #expect(
            playing > ready,
            "`.playing` 早于 `.readyToPlay` ⇒ 内核在文件打开前就宣布在播；实际序列：\(states)"
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

    /// **`absolute+exact` 的落点精度**（`docs/09` §四 D-b 已拍板用 exact）。
    /// 默认的 `absolute` 只到关键帧 ⇒ 落点会明显偏前，这条就是那个偏差的回归网。
    @Test
    func testSeekLandsNearTarget() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("先进入 .playing") { event in
            event == .stateChanged(.playing)
        }

        let target = 1.5
        await harness.kernel.seek(to: target)

        try await waitUntil("currentTime 逼近 \(target)") {
            let snapshot = await harness.kernel.snapshot()
            return abs(snapshot.currentTime - target) < 0.25
        }

        let snapshot = await harness.kernel.snapshot()
        #expect(
            abs(snapshot.currentTime - target) < 0.25,
            "exact seek 的落点应贴近目标；实测 \(snapshot.currentTime) s（目标 \(target) s）"
        )
        await harness.shutdown()
    }

    /// `stop` 之后必须是 `.idle`，且**不得**报 `.finished` ——
    /// 主动停止与"播完了"是两件事，混了 UI 就会在用户按停止时弹"播放结束"。
    @Test
    func testStopDoesNotLookLikeFinish() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("先进入 .playing") { event in
            event == .stateChanged(.playing)
        }

        await harness.kernel.stop()
        try await waitUntil("回到 .idle") {
            await harness.kernel.snapshot().state == .idle
        }
        // 给 END_FILE 一个到达的机会，再看有没有混进 .finished
        try? await Task.sleep(for: .milliseconds(400))

        let states = await harness.states()
        #expect(states.contains(.idle), "实际序列：\(states)")
        #expect(!states.contains(.finished), "主动 stop 不得报 .finished，实际序列：\(states)")
        await harness.shutdown()
    }

    /// **换文件**（`loadfile … replace`）的完整序列实测。
    /// 这是 `P-035` 的同族风险点：换文件会先给定一个"上一个文件结束"的事件，
    /// 若状态机把中间态判为非法，结局就是**永久停在某个状态且零报错**。
    @Test
    func testSwitchingFilesEndsUpPlaying() async throws {
        let first = try await TestClip.makeURL()
        let second = try await TestClip.makeURL()
        defer {
            TestClip.remove(first)
            TestClip.remove(second)
        }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: first))
        try await harness.waitFor("第一个文件进入 .playing") { event in
            event == .stateChanged(.playing)
        }

        try await harness.kernel.load(PlayerResource(url: second))

        // ⚠️ 刻意吞掉超时，让断言把**真实序列**打出来 —— 否则失败只报 ".timedOut"，
        //    等于把"哪一步没发生"这个最有用的信息丢掉。
        let reachedPlaying = (try? await waitUntil("第二个文件也进入 .playing") {
            await harness.kernel.snapshot().state == .playing
        }) != nil
        let snapshot = await harness.kernel.snapshot()
        let states = await harness.states()
        let events = await harness.events()
        #expect(
            reachedPlaying && snapshot.state == .playing,
            """
            换文件后最终应回到 .playing；实测终态 \(snapshot.state)。
            状态序列：\(states)
            全量事件：\(events)
            """
        )
        await harness.shutdown()
    }

    /// **`keep-open=yes` 下播到结尾必须能报 `.finished`。**
    ///
    /// 实测发现 `END_FILE` 在 keep-open 下**不会到达**（播完 15 秒内一条都没有）⇒
    /// 若不额外观察 `eof-reached`，`.finished` 就是**死状态**：
    /// UI 永远不知道"放完了"，也就做不出"播完自动下一集 / 重播"。
    @Test
    func testReachingEndOfClipReportsFinished() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))

        try await harness.waitFor("播完应报 .finished", timeout: .seconds(25)) { event in
            event == .stateChanged(.finished)
        }
        let states = await harness.states()
        #expect(states.contains(.playing), "播完之前应先经历过 .playing，实际序列：\(states)")
        await harness.shutdown()
    }

    // MARK: - 字幕（`G4`）

    /// 拉起一个**正在播放**的内核 —— 字幕断言都建立在"有东西在播"之上。
    /// 返回 (harness, clip)：调用方负责 `TestClip.remove`。
    private func harnessPlaying() async throws -> (KernelHarness, URL) {
        let clip = try await TestClip.makeURL()
        let harness = await KernelHarness()
        try await harness.kernel.load(PlayerResource(url: clip))
        try await harness.waitFor("先进入 .playing") { event in
            event == .stateChanged(.playing)
        }
        return (harness, clip)
    }

    @Test
    func testExternalSubtitleIsEnumeratedAndAutomaticallySelected() async throws {
        let (harness, clip) = try await harnessPlaying()
        let subtitle = try TestSubtitle.makeURL(TestSubtitle.chineseSRT, extension: "srt")
        defer {
            TestClip.remove(clip)
            TestClip.remove(subtitle)
        }

        await harness.kernel.addSubtitle(url: subtitle, title: "中文字幕")
        try await waitUntil("字幕轨出现在状态里") {
            await harness.kernel.snapshot().subtitles.hasSource
        }

        let state = await harness.kernel.snapshot().subtitles
        #expect(state.tracks.count == 1, "实际轨道：\(state.tracks)")
        #expect(state.tracks.first?.isExternal == true, "外挂字幕必须标记为外挂（内挂/外挂要能区分）")
        #expect(state.tracks.first?.title == "中文字幕")
        #expect(state.selectedTrackID != nil, "`sub-add … select` 之后应自动选中")
        #expect(state.isVisible, "mpv 默认 `sub-visibility=yes`")
        #expect(state.isDisplaying)

        // 事件也该到过一次（界面靠它刷新菜单）
        try await harness.waitFor("上报过字幕状态") { event in
            if case .subtitlesChanged(let value) = event { return value.hasSource }
            return false
        }
        await harness.shutdown()
    }

    /// 延迟必须**能设、能回读**（`G4` 的「字幕延迟可调」）。
    @Test
    func testSubtitleDelayIsAppliedAndReadBack() async throws {
        let (harness, clip) = try await harnessPlaying()
        let subtitle = try TestSubtitle.makeURL(TestSubtitle.chineseSRT, extension: "srt")
        defer {
            TestClip.remove(clip)
            TestClip.remove(subtitle)
        }

        await harness.kernel.addSubtitle(url: subtitle, title: nil)
        try await waitUntil("字幕轨就位") { await harness.kernel.snapshot().subtitles.hasSource }

        await harness.kernel.setSubtitleDelay(1.25)
        try await waitUntil("sub-delay 回读为 1.25") {
            abs(await harness.kernel.snapshot().subtitles.delay - 1.25) < 0.001
        }

        let snapshot = await harness.kernel.snapshot()
        #expect(abs(snapshot.subtitles.delay - 1.25) < 0.001, "实测 \(snapshot.subtitles.delay)")
        await harness.shutdown()
    }

    @Test
    func testHidingSubtitlesIsReportedWithoutLosingTracks() async throws {
        let (harness, clip) = try await harnessPlaying()
        let subtitle = try TestSubtitle.makeURL(TestSubtitle.chineseSRT, extension: "srt")
        defer {
            TestClip.remove(clip)
            TestClip.remove(subtitle)
        }

        await harness.kernel.addSubtitle(url: subtitle, title: nil)
        try await waitUntil("字幕轨就位") { await harness.kernel.snapshot().subtitles.hasSource }

        await harness.kernel.setSubtitleVisible(false)
        try await waitUntil("sub-visibility 回读为 false") {
            await harness.kernel.snapshot().subtitles.isVisible == false
        }

        let snapshot = await harness.kernel.snapshot()
        #expect(!snapshot.subtitles.isVisible)
        #expect(!snapshot.subtitles.isDisplaying)
        #expect(snapshot.subtitles.hasSource, "关掉可见性只是不显示，**不该把轨道丢掉**")
        await harness.shutdown()
    }

    /// 选中"无"必须真的落到 `sid=no`，而不是被 `>= 0` 的判断悄悄放过去。
    @Test
    func testClearingSubtitleSelectionIsReported() async throws {
        let (harness, clip) = try await harnessPlaying()
        let subtitle = try TestSubtitle.makeURL(TestSubtitle.chineseSRT, extension: "srt")
        defer {
            TestClip.remove(clip)
            TestClip.remove(subtitle)
        }

        await harness.kernel.addSubtitle(url: subtitle, title: nil)
        try await waitUntil("先有选中的轨") { await harness.kernel.snapshot().subtitles.selectedTrackID != nil }

        await harness.kernel.selectSubtitleTrack(id: nil)

        try await waitUntil("选择被清空") { await harness.kernel.snapshot().subtitles.selectedTrackID == nil }
        let snapshot = await harness.kernel.snapshot()
        #expect(snapshot.subtitles.selectedTrackID == nil)
        #expect(snapshot.subtitles.hasSource, "清掉选择不该影响轨道清单")
        await harness.shutdown()
    }

    /// ASS 走 libass。这里证它**能加载并被枚举**；特效是 libass 的事，
    /// 我们自绘时才需要自己解析样式（`P4-T3` 记为第二期）。
    @Test
    func testASSSubtitleLoads() async throws {
        let (harness, clip) = try await harnessPlaying()
        let subtitle = try TestSubtitle.makeURL(TestSubtitle.effectASS, extension: "ass")
        defer {
            TestClip.remove(clip)
            TestClip.remove(subtitle)
        }

        await harness.kernel.addSubtitle(url: subtitle, title: "ASS")

        try await waitUntil("ASS 轨道出现在状态里") { await harness.kernel.snapshot().subtitles.hasSource }
        let state = await harness.kernel.snapshot().subtitles
        #expect(state.tracks.first?.isExternal == true)
        #expect(state.selectedTrackID != nil)
        await harness.shutdown()
    }

    /// **换文件之后轨道清单必须重建** —— 否则字幕菜单永远停在上一个文件的轨道上。
    ///
    /// ⚠️ 这里**不断言** `selectedTrackID == nil`：实测 mpv 换文件后 `sid` 仍指向旧文件的轨道 id。
    /// 那是 mpv 的表示法，不是我们的契约；我们的契约是**语义**的：解析不到轨 ⇒ 什么都没在显示。
    @Test
    func testSwitchingFilesClearsPreviousSubtitleTracks() async throws {
        let (harness, clip) = try await harnessPlaying()
        let subtitle = try TestSubtitle.makeURL(TestSubtitle.chineseSRT, extension: "srt")
        let secondClip = try await TestClip.makeURL()
        defer {
            TestClip.remove(clip)
            TestClip.remove(secondClip)
            TestClip.remove(subtitle)
        }

        await harness.kernel.addSubtitle(url: subtitle, title: "中文字幕")
        try await waitUntil("字幕轨就位") { await harness.kernel.snapshot().subtitles.hasSource }

        try await harness.kernel.load(PlayerResource(url: secondClip))
        try await waitUntil("换文件后旧字幕轨被清掉") {
            await harness.kernel.snapshot().subtitles.hasSource == false
        }

        let snapshot = await harness.kernel.snapshot()
        #expect(snapshot.subtitles.tracks.isEmpty, "实际轨道：\(snapshot.subtitles.tracks)")
        #expect(snapshot.subtitles.selectedTrack == nil, "陈旧 id 不该解析出轨道")
        #expect(!snapshot.subtitles.isDisplaying, "换文件后不该还在'显示'上一个文件的字幕")
        await harness.shutdown()
    }

    /// **我设的每一项 mpv 选项，mpv 都认吗？**
    ///
    /// 选项名拼错、或当前 mpv 版本不认识它时，`mpv_set_option_string` 只是**返回负值** ——
    /// 不抛异常、不打印。那个选项就静默不生效，而代码看上去完全正确。
    /// 这条用例把"**我设了**"变成"**它认了**"（`P5-T2` 的验证基础）。
    @Test
    func testEveryConfiguredOptionIsAcceptedByMPV() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        // 选项是在 `prepare()` 里设的 ⇒ 触发一次加载让它跑起来。
        try await harness.kernel.load(PlayerResource(url: url))

        let rejected = await harness.kernel.rejectedOptionNames()
        #expect(
            rejected.isEmpty,
            "以下选项 mpv 没有接受（名字拼错或版本不支持）⇒ 它们**静默不生效**：\(rejected)"
        )
        await harness.shutdown()
    }

    /// **带请求头加载时，`http-header-fields` / `user-agent` 都必须被 mpv 认。**
    ///
    /// 为什么这条必要：`setOption` 失败**不抛错**，只记进 `rejectedOptions`。
    /// 所以"我设了头"与"头生效了"是两件事 —— 这条用例专门盯住前者不许静默。
    /// （真正"头有没有发出去"由 `serve-range.py --echo-headers` 的端到端取证回答。）
    @Test
    func testRequestHeadersAreAcceptedByMPV() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(
            PlayerResource(
                url: url,
                headers: ["X-Player-Test": "yes", "User-Agent": "PlayerStack-Test/2.0"]
            )
        )

        let rejected = await harness.kernel.rejectedOptionNames()
        #expect(rejected.isEmpty, "请求头相关选项被 mpv 拒绝 ⇒ 自定义头**静默不生效**：\(rejected)")
        await harness.shutdown()
    }

    /// **实时源的短探测窗口，mpv 必须认。**
    ///
    /// 取值规则由 `StreamProbePlanTests` 用纯逻辑钉死；这里只回答另一半 ——
    /// "我设了"是否等于"它认了"（`P5-T2` 的判据：选项写错名字时**只返回负值、不报错**）。
    ///
    /// ⚠️ 刻意**不真的连流**：选项是在 `mpv_initialize` **之前**设的，
    /// 所以"设了没有"不需要一个能连上的服务器（要服务器就会让夹具不确定，`P-033`）。
    @Test
    func testRealtimeProbeWindowOptionIsAcceptedByMPV() async throws {
        let harness = await KernelHarness()
        let url = try #require(URL(string: "rtsp://127.0.0.1:8554/playerlearning-probe-test"))

        try? await harness.kernel.load(PlayerResource(url: url))

        let rejected = await harness.kernel.rejectedOptionNames()
        #expect(rejected.isEmpty, "以下选项 mpv 没接受 ⇒ 短窗口**静默不生效**：\(rejected)")
        await harness.shutdown()
    }

    /// **换文件时必须重设请求头。**
    ///
    /// mpv 的选项挂在句柄上：不重设，上一个文件的头会**继续发给下一个文件**，而且不报错。
    /// 这条同时盯住"运行期能不能改"这件事 —— 首次加载是在 `mpv_initialize` 之前设的，
    /// 换文件走的是运行期重设，两条路都得被接受。
    @Test
    func testLoadingAnotherResourceResetsRequestHeaders() async throws {
        let first = try await TestClip.makeURL()
        let second = try await TestClip.makeURL()
        defer {
            TestClip.remove(first)
            TestClip.remove(second)
        }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: first, headers: ["X-First": "1"]))
        try await harness.kernel.load(PlayerResource(url: second, headers: ["X-Second": "2"]))

        let rejected = await harness.kernel.rejectedOptionNames()
        #expect(rejected.isEmpty, "运行期重设请求头被 mpv 拒绝 ⇒ 换文件后会继续发旧头：\(rejected)")
        await harness.shutdown()
    }

    // MARK: - 视频轨（`P5-T5`「可切清晰度」）

    /// **单码率源的视频轨必须被枚举出来**，分辨率与选中项都要对。
    ///
    /// ⚠️ 这里刻意**不测多档切换**：HLS 多码率源要外部 `ffmpeg` + HTTP 服务，
    /// 夹具就不确定了（`P-033`）。多档行为已在 `docs/14` 用**本地三档源**实测过 ——
    /// 那是**一次性探针**，不是常驻测试。
    /// 本用例盯的是**常驻的翻译层**：`track-list` → `VideoTrack` 的字段映射（`demux-w/h`）与 `vid` 回读。
    @Test
    func testVideoTrackIsEnumeratedWithResolution() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))

        try await waitUntil("视频轨出现在状态里") {
            await harness.kernel.snapshot().videoTracks.tracks.isEmpty == false
        }

        let state = await harness.kernel.snapshot().videoTracks
        #expect(state.tracks.count == 1, "本地 mp4 只有一条视频轨；实际：\(state.tracks)")
        let track = try #require(state.tracks.first)
        #expect(track.width == TestClip.width, "档位标签取 `track-list/N/demux-w`；实测 \(track.width)")
        #expect(track.height == TestClip.height, "档位标签取 `track-list/N/demux-h`；实测 \(track.height)")
        #expect(track.label.hasPrefix("\(TestClip.width)×\(TestClip.height)"))
        #expect(state.selectedTrackID == track.id, "正在解的那一条就是选中项")
        #expect(state.selectedTrack != nil)
        #expect(!state.hasAlternatives, "单码率不该显示「清晰度」菜单（只有一项的菜单是噪音）")

        // 事件也该到过一次（界面靠它刷新菜单）
        try await harness.waitFor("上报过视频轨状态") { event in
            if case .videoTracksChanged(let value) = event { return !value.tracks.isEmpty }
            return false
        }
        await harness.shutdown()
    }

    /// **选中视频轨要能落下去、并且回读得到** —— 证 `vid` 的写-读路径真的通，
    /// 而不是被静默忽略（`P-049` 那族：设了不等于生效）。
    ///
    /// 单档素材下"切到自己"是唯一**确定性**的选择，但它完整走了 `setProperty` + 回读那条路。
    @Test
    func testSelectingVideoTrackIsAppliedAndReadBack() async throws {
        let (harness, clip) = try await harnessPlaying()
        defer { TestClip.remove(clip) }

        try await waitUntil("视频轨就位") {
            await harness.kernel.snapshot().videoTracks.tracks.isEmpty == false
        }
        let target = try #require(await harness.kernel.snapshot().videoTracks.tracks.first)

        await harness.kernel.selectVideoTrack(id: target.id)

        try await waitUntil("`vid` 回读为同一条") {
            await harness.kernel.snapshot().videoTracks.selectedTrackID == target.id
        }
        let state = await harness.kernel.snapshot().videoTracks
        #expect(state.selectedTrackID == target.id)
        #expect(state.selectedTrack != nil)
        #expect(state.label == "清晰度：\(target.label)")
        await harness.shutdown()
    }

    // MARK: - 播放控制（`stop` / `play` 的真实语义）

    /// **「停止」之后再点「播放」必须能重新播起来。**
    ///
    /// 这是实测反馈"点播放按钮无效"的第一种情形：mpv 的 `stop` 命令会**清空播放列表**，
    /// 此后 `pause=no` 不会让任何东西播起来 —— 必须把文件重新放回去。
    /// 「停止 → 播放」在播放器语义里就是「从头再播一次」。
    @Test
    func testPlayAfterStopResumesFromStart() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("先进入 .playing") { $0 == .stateChanged(.playing) }

        await harness.kernel.stop()
        try await waitUntil("回到 .idle") { await harness.kernel.snapshot().state == .idle }

        await harness.kernel.play()

        let resumed = (try? await waitUntil("stop 之后 play 应重新播起来", timeout: .seconds(12)) {
            await harness.kernel.snapshot().state == .playing
        }) != nil
        let states = await harness.states()
        #expect(
            resumed,
            "「停止」会清空 mpv 播放列表 ⇒ 此时设 pause=no 不会让任何东西播起来。实测状态序列：\(states)"
        )
        await harness.shutdown()
    }

    /// **播完之后点「播放」应从头重播**，而不是停在末帧"看起来没反应"。
    ///
    /// `keep-open=yes` 下 mpv 停在末尾且 `pause=yes`，此时设 `pause=no` 只会在末帧上
    /// 立刻再次 EOF ⇒ 用户按下播放键但画面不动。
    ///
    /// ⚠️ **两条断言纪律 —— 这一条用例的第一版两条都没做到，于是放过了真缺陷**：
    /// ① 播完之后**必须再等一拍**（等 EOF 的那些连带变化到达）。真机上用户是几秒后才点的。
    /// ② 断言必须写「**时间真的在推进**」，不能写「现在小于某个值」——
    ///    停在末帧不动的 `currentTime` 同样满足 `currentTime < duration - 0.5`
    ///    （末帧的时间本来就比片尾小），那种断言对"画面没动"**恒真**。
    ///
    /// ⚠️ **还要断言状态轨迹**：真机实测（`-exerciseFinish`）修复前的表现是
    /// **画面已经在重播、内核只报了 `.playing`** —— 而 `.finished → .playing` 在装配层
    /// 是**非法迁移**（`docs/03` 记录过：`.finished` 是终态），于是那条上报被如实拒收，
    /// 界面**永远停在 `finished`**：按钮不换、状态行不改。用户看到的就是「点了没反应」。
    /// 只断言"时间推进"抓不到它 —— **必须连"报了什么状态"一起断言**。
    @Test
    func testPlayAfterFinishRestartsFromBeginning() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("播完", timeout: .seconds(25)) { $0 == .stateChanged(.finished) }
        try await Task.sleep(for: .seconds(1.5))
        let before = await harness.kernel.snapshot().currentTime

        await harness.kernel.play()

        let restarted = (try? await waitUntil("应从头重新推进", timeout: .seconds(15)) {
            let snapshot = await harness.kernel.snapshot()
            return snapshot.state == .playing && snapshot.currentTime < before - 1
        }) != nil
        let snapshot = await harness.kernel.snapshot()
        #expect(
            restarted,
            "播完后 play 应从头重播；实测 \(snapshot.state) @ \(snapshot.currentTime) s（播完时是 \(before) s）"
        )

        // 重播必须重新走一遍 `preparing → readyToPlay`：`.finished` 是终态，
        // 装配层**只接受**这条路径。直接报 `.playing` 会被拒收（真机实测）。
        //
        // ⚠️ 断言写成「**最后一个 `.finished` 之后**以 `preparing → readyToPlay` 开头」，
        // 而不是「最后四个正好是那四个」：mpv 之后会把 `pause` 再报一次，
        // 于是尾部可能多一个重复的 `.playing`（实测）。
        // **重复上报不是缺陷，顺序才是** —— 把断言卡在"恰好几个"上会假红。
        let states = await harness.states()
        let afterFinish = states.lastIndex(of: .finished).map { Array(states[($0 + 1)...]) } ?? []
        #expect(
            afterFinish.starts(with: [.preparing, .readyToPlay]) && afterFinish.contains(.playing),
            "重播必须重新走一遍 preparing → readyToPlay；实测重播后的状态：\(afterFinish)"
        )
        await harness.shutdown()
    }

    /// **`pause=no` 不等于「正在播放」。**
    ///
    /// 实测：暂停中按「停止」，mpv 会把 `pause` 重置为 `no`。
    /// 若把这条属性变化直接当状态，
    /// 内核自己的 `state` 会被污染成 `.playing` —— 而实际上已经停了。
    @Test
    func testStopWhilePausedDoesNotLookLikePlaying() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("先进入 .playing") { $0 == .stateChanged(.playing) }
        await harness.kernel.pause()
        try await waitUntil("进入 .paused") { await harness.kernel.snapshot().state == .paused }

        await harness.kernel.stop()
        try await waitUntil("回到 .idle") { await harness.kernel.snapshot().state == .idle }
        // 给 `pause` 的连带变化（`yes` → `no`）一个到达的机会
        try? await Task.sleep(for: .milliseconds(500))

        let snapshot = await harness.kernel.snapshot()
        #expect(
            snapshot.state == .idle,
            "stop 之后 pause 被重置为 no，不该把状态拽回 .playing；实测 \(snapshot.state)"
        )
        await harness.shutdown()
    }

    // MARK: - 起播时间线（`P6-T4`）

    /// **文件还没打开完，内核不能报「正在播放」。**
    ///
    /// 这是起播埋点顺手照出来的第二个缺陷。`[startup]` 显示：`load()` + `play()` 之后
    /// **2 ms** 就报了 `.playing`，而 `file-loaded` 要 **57–1200 ms** 才到 —— 早了三个数量级。
    /// 对**打不开的文件**更荒谬：先报 `.playing`，再报 `.failed`。
    ///
    /// 为什么一直没被发现：装配层（`PlayerStateMachine`）恰好把 `.preparing → .playing`
    /// 列为**非法边**，于是那句话被静默拒收、界面从没显示错状态。
    /// 但内核自己的 `state` 确实是假的 —— **`snapshot()` 会给任何消费者同一个假答案**。
    /// 判据同 `P-038`：靠"下游正好把它挡掉了"活着，不叫正确。
    @Test
    func testPlayingIsNotAnnouncedWhileTheFileIsStillOpening() async throws {
        let harness = await KernelHarness()
        let missing = URL(fileURLWithPath: "/nonexistent/playerlearning-missing.mkv")

        try? await harness.kernel.load(PlayerResource(url: missing))
        // 真机上的调用顺序就是这样（`loadDirect` = load 之后紧跟 play）。
        await harness.kernel.play()

        try await harness.waitFor("出现 .failed") { $0 == .stateChanged(.failed) }
        let states = await harness.states()
        #expect(
            !states.contains(.playing),
            "文件根本没打开，不该出现 `.playing`（那是句无法支持的话）；实际序列：\(states)"
        )
        await harness.shutdown()
    }

    /// **起播的每个节点都要被打上，而且顺序必须是对的。**
    ///
    /// 为什么这条本身值得测：分段是**归因的前提** —— 缺一个节点，
    /// "哪一段占了多少"就算错；顺序错了（比如 `vo-configured` 跑到 `file-loaded` 之前），
    /// 归因方向整个反掉，而两种情况都**不会报错**，只会给出一张看起来正常的表。
    ///
    /// ⚠️ 这里**不断言** `playing` 与 `vo-configured` 的先后，只断言它们都在、
    /// 且都晚于 `file-loaded`：实测两者的先后是**环境相关**的（那是被量的对象，不是契约）。
    @Test
    func testStartupTimelineIsCompleteAndOrdered() async throws {
        let url = try await TestClip.makeURL()
        defer { TestClip.remove(url) }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: url))
        try await harness.waitFor("先播起来") { $0 == .stateChanged(.playing) }

        // 「出画」晚于「内核说在播」是本票要量的东西 ⇒ 必须**单独等它**，
        // 等不到就是红，而不是"读一份没有它的残表然后看似正常地通过"。
        try await waitUntil("报告视频输出已配置", timeout: .seconds(20)) {
            await harness.kernel.startupTimeline().mark(StartupTimeline.Step.voConfigured) != nil
        }

        let timeline = await harness.kernel.startupTimeline()
        let names = timeline.marks.map(\.name)
        #expect(names.first == StartupTimeline.Step.loadEntered, "第一个节点必须是 load 入口；实际：\(names)")

        let required = [
            StartupTimeline.Step.handleCreated,
            StartupTimeline.Step.optionsApplied,
            StartupTimeline.Step.initialized,
            StartupTimeline.Step.loadfileSent,
            StartupTimeline.Step.fileLoaded,
            StartupTimeline.Step.voConfigured,
            StartupTimeline.Step.playing,
        ]
        for step in required {
            #expect(names.contains(step), "缺节点 `\(step)`；实际：\(names)")
        }

        // 单调：相对毫秒必须随节点顺序递增（时钟取错或算错都会破坏它）。
        let times = timeline.marks.map(\.milliseconds)
        #expect(times == times.sorted(), "时间线必须单调不减；实际：\(times)")

        let sent = try #require(timeline.mark(StartupTimeline.Step.loadfileSent))
        let loaded = try #require(timeline.mark(StartupTimeline.Step.fileLoaded))
        let firstFrame = try #require(timeline.mark(StartupTimeline.Step.voConfigured))
        #expect(sent <= loaded, "`loadfile` 必须先发出、再收到 FILE_LOADED")
        #expect(loaded <= firstFrame, "FILE_LOADED 必须早于出画")
        await harness.shutdown()
    }

    /// **换文件是一次新的起播** ⇒ 时间线必须重来。
    ///
    /// 不重来会怎样：读到的数字全是**上一次**的，而且它们**依旧自洽**
    /// （顺序对、单调、节点齐全）⇒ 读的人看不出区别，只会拿上一轮的耗时去解释这一轮。
    /// 同族风险：`P-038`（「问现在是什么，别信本地记的那一份」）。
    @Test
    func testStartupTimelineRestartsOnEveryLoad() async throws {
        let first = try await TestClip.makeURL()
        let second = try await TestClip.makeURL()
        defer {
            TestClip.remove(first)
            TestClip.remove(second)
        }
        let harness = await KernelHarness()

        try await harness.kernel.load(PlayerResource(url: first))
        try await harness.waitFor("第一个文件播起来") { $0 == .stateChanged(.playing) }
        let firstTimeline = await harness.kernel.startupTimeline()
        #expect(
            firstTimeline.mark(StartupTimeline.Step.handleCreated) != nil,
            "首次加载会建句柄，必须留下这一节点；实际：\(firstTimeline.marks.map(\.name))"
        )

        try await harness.kernel.load(PlayerResource(url: second))
        let secondTimeline = await harness.kernel.startupTimeline()
        let names = secondTimeline.marks.map(\.name)

        #expect(
            secondTimeline.mark(StartupTimeline.Step.handleCreated) == nil,
            "换文件不会重建句柄 ⇒ 上一轮的节点不该还在；实际：\(names)"
        )
        let restartedAt = try #require(secondTimeline.mark(StartupTimeline.Step.loadEntered))
        #expect(restartedAt < 1, "新一轮的起点必须归零；实际：\(secondTimeline.marks)")
        await harness.shutdown()
    }
}
#endif
