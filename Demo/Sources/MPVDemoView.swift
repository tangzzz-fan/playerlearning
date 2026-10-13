import CoreGraphics
import Foundation
import Observation
import PlayerCore
import PlayerMPV
import PlayerUI
import SwiftUI

/// Phase 2 的端到端样板：**surface → 内核 → 装配层 → UI**，四层真的连起来。
///
/// 它存在的意义不是"长得好看"（那属 P3 的 5 件套），而是把"真画面出来"这条链路
/// 变成**可以亲手点一下**的东西 —— `G2` 的判定需要它。
@MainActor
@Observable
final class MPVDemoModel {
    private(set) var state: PlayerState = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var naturalSize: CGSize = .zero
    private(set) var isBuffering = false
    private(set) var statusText = "未开始"
    private(set) var isReady = false

    let output = WindowEmbedOutput()

    private var controller: PlayerController?
    private var pump: Task<Void, Never>?
    private var memory: Task<Void, Never>?
    /// `-traceUpdates`：把每次更新打到 stdout —— 端到端排查**必须**能看见事件的真实时序，
    /// 否则只能靠截图猜（`xcrun simctl launch --console …` 能收到这些输出）。
    private let traces = ProcessInfo.processInfo.arguments.contains("-traceUpdates")
    /// 进程启动时刻 —— 时间戳用**单调**的相对秒数，便于直接算"首屏耗时"这类指标。
    private let origin = Date()

    /// 等 surface 就位后再建内核 —— 顺序不可交换（见 `VideoSurfaceView` 的说明）。
    func activate() async {
        guard controller == nil, let handle = output.windowEmbedHandle else { return }
        let controller = PlayerController(kernel: MPVKernel(windowEmbedHandle: handle))
        self.controller = controller

        let updates = await controller.start()
        pump = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.apply(update)
            }
        }

        let snapshot = await controller.snapshot()
        state = snapshot.state
        isReady = true
        statusText = "内核就绪（headless 关闭：已绑定 wid 句柄）"

        // 可脚本化的端到端入口：`xcrun simctl launch <udid> com.playerstack.demo -autoLoadSample`
        // ⇒ 命令行就能驱动"加载样例 + 播放"，G2 的判定不必依赖手点。
        if traces {
            memory = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if let footprint = MemoryFootprint.megabytes() {
                        FileHandle.standardError.write(
                            Data("[mem] \(String(format: "%7.3f", Date().timeIntervalSince(self.origin))) \(String(format: "%.1f", footprint)) MB\n".utf8)
                        )
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        if ProcessInfo.processInfo.arguments.contains("-autoLoadSample") {
            await loadSample()
            await play()
        }
    }

    func loadSample() async {
        guard let controller else { return }
        do {
            statusText = "正在生成样例片段…"
            let url = try await SampleClipWriter.ensureClip()
            statusText = "加载 \(url.lastPathComponent)"
            try await controller.load(PlayerResource(url: url))
        } catch {
            statusText = "加载失败：\(error)"
        }
    }

    func play() async { await controller?.play() }
    func pause() async { await controller?.pause() }
    func stop() async { await controller?.stop() }
    func seek(to seconds: Double) async { await controller?.seek(to: seconds) }
    func skip(by delta: Double) async { await controller?.seek(to: currentTime + delta) }

    func deactivate() {
        pump?.cancel()
        pump = nil
        memory?.cancel()
        memory = nil
    }

    private func apply(_ update: PlayerControllerUpdate) {
        trace(update)
        switch update {
        case .stateChanged(let newState):
            state = newState
        case .timeChanged(let time):
            currentTime = time.currentTime
            duration = time.duration
        case .bufferingChanged(let flag):
            isBuffering = flag
        case .videoSizeChanged(let size):
            naturalSize = size
        }
    }

    private func trace(_ update: PlayerControllerUpdate) {
        guard traces else { return }
        // ⚠️ 必须走**无缓冲**的 stderr 直写：`print` 是 stdout，在管道下是**块缓冲**，
        // 而排查端到端免不了要 terminate 应用 —— 缓冲会被一起带走，表现为"一行输出都没有"
        // （与 `P-014` 家族同源：没有输出推不出任何结论，见 `P-040`）。
        FileHandle.standardError.write(Data("[trace] \(String(format: "%7.3f", Date().timeIntervalSince(origin))) \(update)\n".utf8))
    }
}

struct MPVDemoView: View {
    @State private var model = MPVDemoModel()

    var body: some View {
        VStack(spacing: 0) {
            VideoSurfaceView(output: model.output)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)

            statusPanel

            controls
        }
        .navigationTitle("Phase 2 · 端到端")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.activate() }
        .onDisappear { model.deactivate() }
    }

    private var statusPanel: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("状态", "\(model.state)")
            row("时间", String(format: "%.2f / %.2f s", model.currentTime, model.duration))
            row("画面", "\(Int(model.naturalSize.width))×\(Int(model.naturalSize.height))")
            row("缓冲", model.isBuffering ? "是" : "否")
            row("说明", model.statusText)
        }
        .font(.footnote.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).gridColumnAlignment(.leading)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button("加载样例") { Task { await model.loadSample() } }
                Button("播放") { Task { await model.play() } }
                Button("暂停") { Task { await model.pause() } }
                Button("停止") { Task { await model.stop() } }
            }
            HStack {
                Button("−10 s") { Task { await model.skip(by: -10) } }
                Button("−1 s") { Task { await model.skip(by: -1) } }
                Button("+1 s") { Task { await model.skip(by: 1) } }
                Button("+10 s") { Task { await model.skip(by: 10) } }
            }
        }
        .buttonStyle(.bordered)
        .disabled(!model.isReady)
        .padding(12)
    }
}
