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
        if let rounds = soakRounds {
            await soakTest(rounds: rounds)
        } else if ProcessInfo.processInfo.arguments.contains("-exerciseControls") {
            await exerciseControls()
        } else if ProcessInfo.processInfo.arguments.contains("-autoLoadSample") {
            await loadSample()
            await player.play()
        }
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
