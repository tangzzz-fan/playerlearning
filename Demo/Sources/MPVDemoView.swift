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
        if traces {
            startMemorySampling()
        }
        if ProcessInfo.processInfo.arguments.contains("-autoLoadSample") {
            await loadSample()
            await player.play()
        }
    }

    func teardown() async {
        memory?.cancel()
        memory = nil
        await player.teardown()
    }

    func loadSample() async {
        do {
            note = "正在生成样例片段…"
            let url = try await SampleClipWriter.ensureClip()
            note = "已载入 \(url.lastPathComponent)"
            await player.load(PlayerResource(url: url))
        } catch {
            note = "生成样例失败：\(error)"
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

            HStack(spacing: 12) {
                Button("载入样例") { Task { await demo.loadSample() } }
                    .accessibilityIdentifier("demo.loadSample")
                Button("停止") { Task { await demo.player.stop() } }
                    .accessibilityIdentifier("demo.stop")
                Button("−10 s") { Task { await demo.player.skip(by: -10) } }
                    .accessibilityIdentifier("demo.back10")
                Button("+10 s") { Task { await demo.player.skip(by: 10) } }
                    .accessibilityIdentifier("demo.forward10")
                Text(demo.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("demo.note")
            }
            .buttonStyle(.bordered)
            .padding(12)
        }
        .task { await demo.start() }
        .onDisappear { Task { await demo.teardown() } }
    }
}
