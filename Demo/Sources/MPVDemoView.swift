import CoreGraphics
import Foundation
import Observation
import PlayerCore
import PlayerMPV
import PlayerUI
import SwiftUI

/// App 层的**装配点**：把表面、内核、控制器、视图模型按正确顺序拧在一起。
///
/// ⚠️ 顺序不可交换：`表面` 先给出 `wid` 句柄 → 才能构造内核（`wid` 必须在 `mpv_initialize` 之前）
/// → 才能构造控制器与视图模型。`PlayerUI` 刻意不认识 libmpv，就是为了让这段装配留在这里。
@MainActor
@Observable
final class PlayerDemoModel {
    let surface: WindowEmbedOutput
    let player: PlayerViewModel
    private(set) var note = ""

    private let traces = ProcessInfo.processInfo.arguments.contains("-traceUpdates")
    private let origin = Date()
    private var memory: Task<Void, Never>?

    init() {
        let surface = WindowEmbedOutput()
        self.surface = surface

        guard let handle = surface.windowEmbedHandle else {
            // 表面一定给得出句柄（它就是自身指针）。走到这里说明实现坏了，
            // ⇒ **大声死**，而不是静默退回无画面（那正是 `P2-T7` 要消灭的失败形态）。
            fatalError("WindowEmbedOutput 未给出 wid 句柄")
        }
        player = PlayerViewModel(controller: PlayerController(kernel: MPVKernel(windowEmbedHandle: handle)))

        if traces {
            player.onUpdate = { [origin] update in
                Self.writeToStderr("[trace] \(Self.stamp(at: origin)) \(update)")
            }
        }
    }

    func start() async {
        await player.start()
        if traces || soakRounds != nil {
            startMemorySampling()
        }
        if traces {
            // `-traceUpdates` 同时打开**内核自己的日志**：网络流为什么没播起来、
            // 编码为什么解不开 —— 这些从我们的状态机里看不出来（我们只看到"它说 EOF 了"）。
            await player.enableKernelLogging { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
        if let rounds = soakRounds {
            await soakTest(rounds: rounds)
        } else if ProcessInfo.processInfo.arguments.contains("-exerciseControls") {
            await exerciseControls()
        } else if ProcessInfo.processInfo.arguments.contains("-exerciseFinish") {
            await exerciseFinish()
        } else if let direct = directURL, let url = URL(string: direct) {
            await loadDirect(url)
        } else if ProcessInfo.processInfo.arguments.contains("-autoLoadSample") {
            await loadSample()
            await player.play()
        }
    }

    /// `-directURL <url>`：把 URL **直接交给播放器**（不经过下载与缓存）。
    ///
    /// ⚠️ 与 `-sampleURL` 的区别是本质的，不是方便与否：
    /// `-sampleURL` 走 `SampleClipProvider` —— 它用 **URLSession 下载到本地再播**，
    /// 那条路径验证的是**下载**，而 `mpv` 收到的一直是一个本地文件。
    /// 要验证 **mpv 自己的网络流**（HTTP 协议栈、缓存策略、弱网行为），
    /// 必须把 `http://` URL **原样交给它**。
    /// 没有这条入口时，「网络点播」这件事在验证里是**缺席**的。
    private var directURL: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-directURL"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// 直连播放。**不做任何下载/缓存**，把 URL 原样给内核。
    func loadDirect(_ url: URL) async {
        note = "直连：\(url.absoluteString)"
        Self.writeToStderr("[direct] url=\(url.absoluteString)")
        await player.load(PlayerResource(url: url))
        await player.play()
    }

    /// `-soakRounds <n>`：长跑/循环稳定性（每轮 ≈ 10 s）。
    ///
    /// 为什么需要它：此前**所有**验证都在 5–52 秒的量级上做的。
    /// 而播放器最容易出问题的场景恰恰是**反复加载、反复 seek、长时间不停**：
    /// 内存是否单调增长、解码/音频线程有没有堆积、`AsyncStream` 的消费者有没有泄漏。
    /// **这类问题在 1 分钟里完全看不出来** —— 它们需要"次数"和"时间"才显形。
    ///
    /// 每轮刻意把**所有控制路径**都走一遍（load → play → seek → pause → play → stop），
    /// 因为泄漏往往藏在某一条具体路径上，只播不切是测不到的。
    private var soakRounds: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-soakRounds"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    private func soakTest(rounds: Int) async {
        Self.writeToStderr("[soak] start rounds=\(rounds)")
        for round in 1 ... rounds {
            await loadSample()
            await player.play()
            try? await Task.sleep(for: .seconds(4))

            await player.seek(to: 20)
            try? await Task.sleep(for: .seconds(2))

            await player.pause()
            try? await Task.sleep(for: .seconds(1))
            await player.play()
            try? await Task.sleep(for: .seconds(2))

            await player.stop()
            try? await Task.sleep(for: .seconds(1))

            let footprint = MemoryFootprint.megabytes().map { String(format: "%.1f", $0) } ?? "?"
            Self.writeToStderr(
                "[soak] round \(round)/\(rounds) · t=\(Self.stamp(at: origin)) · footprint=\(footprint) MB · state=\(player.state)"
            )
        }
        Self.writeToStderr("[soak] done")
    }

    /// 把「加载 → 播 → 停 → 再播」跑一遍并逐拍打点。
    ///
    /// 为什么需要它：**点击本身没法自动化**（UI 自动化测试已按董事长决定移除），
    /// 但"点了没反应"正是本轮要修的观感 —— 只靠单测不足以证明真机路径通了。
    /// 这里走的是与按钮**完全相同**的 action（`player.stop()` / `player.play()`），
    /// 所以能证"控制链路 + 内核语义"在真实 libmpv 上是通的；
    /// **不能**证明的只有一件事：手指有没有点到按钮上。
    private func exerciseControls() async {
        await loadSample()
        try? await Task.sleep(for: .seconds(3))
        Self.writeToStderr("[exercise] loaded → \(player.state) canPlay=\(player.canPlay) canStop=\(player.canStop)")

        await player.stop()
        try? await Task.sleep(for: .seconds(2))
        Self.writeToStderr("[exercise] stopped → \(player.state) canPlay=\(player.canPlay) canStop=\(player.canStop)")

        await player.play()
        try? await Task.sleep(for: .seconds(3))
        Self.writeToStderr("[exercise] replayed → \(player.state) t=\(String(format: "%.2f", player.currentTime))")
    }

    func teardown() async {
        memory?.cancel()
        memory = nil
        await player.teardown()
    }

    /// `-exerciseFinish`：**播到结尾之后再点「播放」**，走与按钮**完全相同**的 action。
    ///
    /// 为什么单开一条入口：`-exerciseControls` 覆盖的是「停止 → 再播」，那条路径 mpv 的
    /// 播放列表**为空**（`stop` 清空了它）⇒ 走"重新 `loadfile`"。而真机上最刺眼的是
    /// 「**播完** → 再播」—— 它停在末帧（`keep-open`），播放列表**没空**，是另一条路径。
    /// 两条路径的症状都是"点了没反应"，成因却完全不同。
    ///
    /// ⚠️ 它证明的仍然只是**按钮按下之后**那段；"手指有没有点到按钮上"依旧只能肉眼确认。
    private func exerciseFinish() async {
        await loadSample()
        await player.play()
        try? await Task.sleep(for: .seconds(1))
        // 直接跳到片尾前 2 秒再播到头：等整片（52 s）跑完太浪费，而"停在末帧"这个终局一样。
        await player.seek(to: max(0, player.duration - 2))
        try? await Task.sleep(for: .seconds(5))
        Self.writeToStderr("[finish] 播到末尾 → \(Self.snapshot(player))")

        // ⚠️ 这一拍是关键：真机上用户是**过一会儿**才点的，而"刚播完立刻点"是另一条时序。
        try? await Task.sleep(for: .seconds(2))
        Self.writeToStderr("[finish] 等 2 秒后 → \(Self.snapshot(player))")

        await player.play()
        try? await Task.sleep(for: .seconds(3))
        Self.writeToStderr("[finish] 点播放 3 秒后 → \(Self.snapshot(player))")
    }

    /// 打印"用户看得见的那几项"：状态 / 位置 / 时长 / 进度 / 按钮可用性。
    /// 进度条走不满、时间停在末帧前一格 —— 这些都能从这一行直接读出来。
    private static func snapshot(_ player: PlayerViewModel) -> String {
        let time = String(format: "%.2f/%.2f", player.currentTime, player.duration)
        let progress = String(format: "%.3f", player.progress)
        return "state=\(player.state) t=\(time) progress=\(progress) canPlay=\(player.canPlay) canStop=\(player.canStop)"
    }

    /// `-sampleURL <url>` 可覆盖样例来源（排查用；也给"换一个真实素材复验"留了口子）。
    private let sampleURLOverride: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-sampleURL"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    func loadSample() async {
        note = "正在准备样例视频…"
        guard let clip = await SampleClipProvider.ensureClip(overrideURL: sampleURLOverride) else {
            note = "样例视频不可用（下载与本地生成都失败）"
            Self.writeToStderr("[sample] source=none")
            return
        }
        let bytes = (try? clip.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        note = "已载入 \(clip.url.lastPathComponent)（\(clip.source.rawValue)）"
        // 来源必须**上 trace**：G2 要判断"这份素材到底是什么"。
        // 若这里静默退回"本地生成"，断言仍会绿，而"用真实视频验证"这件事其实没发生 ——
        // 那正是 `P-034` 的形态（没被执行的事返回绿）。所以让门禁看得见它。
        Self.writeToStderr("[sample] source=\(clip.source.rawValue) bytes=\(bytes) path=\(clip.url.path)")
        await player.load(PlayerResource(url: clip.url))

        // 同名 sidecar 字幕（`flower.srt` / `flower.ass`）自动挂上 —— 与真实播放器一致。
        if let subtitle = SampleClipProvider.sidecarSubtitle(for: clip) {
            await player.loadSubtitle(from: subtitle)
            Self.writeToStderr("[sample] subtitle=\(subtitle.lastPathComponent)")
        }
    }

    private func startMemorySampling() {
        memory = Task { [origin] in
            while !Task.isCancelled {
                if let footprint = MemoryFootprint.megabytes() {
                    Self.writeToStderr("[mem] \(Self.stamp(at: origin)) \(String(format: "%.1f", footprint)) MB")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 无缓冲直写 stderr：`print` 是 stdout，在管道下是**块缓冲**，
    /// 而排查端到端免不了 terminate 应用 —— 缓冲会被一起带走，表现为"一行输出都没有"（`P-040`）。
    private static func writeToStderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func stamp(at origin: Date) -> String {
        String(format: "%7.3f", Date().timeIntervalSince(origin))
    }
}

struct MPVDemoView: View {
    @State private var demo = PlayerDemoModel()

    var body: some View {
        VStack(spacing: 0) {
            PlayerScreenView(model: demo.player, surface: demo.surface)

            // 全屏时收起调试按钮（宿主外壳要让位）—— 这是"全屏"该有的样子。
            // 非全屏时也刻意做紧凑：这行是**调试入口**，不该跟播放器抢屏幕
            // （上一版用默认尺寸 + 长文案，"载入样例"被折成两行，白占一大块）。
            if !demo.player.fullscreen.hidesHostChrome {
                HStack(spacing: 8) {
                    Button("样例") { Task { await demo.loadSample() } }
                        .accessibilityIdentifier("demo.loadSample")
                    // 三个按钮都跟着播放器的可用性走：没加载过文件时它们**本来就无效**
                    // （内核句柄尚未创建），灰掉比"点了没反应"诚实。
                    Button("停止") { Task { await demo.player.stop() } }
                        .disabled(!demo.player.canStop)
                        .accessibilityIdentifier("demo.stop")
                    Button("−10s") { Task { await demo.player.skip(by: -10) } }
                        .disabled(!demo.player.canSkip)
                        .accessibilityIdentifier("demo.back10")
                    Button("+10s") { Task { await demo.player.skip(by: 10) } }
                        .disabled(!demo.player.canSkip)
                        .accessibilityIdentifier("demo.forward10")

                    Text(demo.note)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("demo.note")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .task { await demo.start() }
        .onDisappear { Task { await demo.teardown() } }
    }
}
