import Foundation

public protocol PlayerKernelProtocol: Sendable {
    init()

    func load(_ resource: PlayerResource) async throws
    func play() async
    func pause() async
    func stop() async
    func seek(to seconds: Double) async
    /// 加一条**外挂**字幕。`title` 为 `nil` 时内核自行取文件名。
    func addSubtitle(url: URL, title: String?) async
    /// 选中某条字幕轨；`nil` = 关掉当前选择（mpv 的 `sid=no`）。
    func selectSubtitleTrack(id: Int64?) async
    /// 要不要显示字幕（`sub-visibility`）。
    func setSubtitleVisible(_ visible: Bool) async
    /// 字幕延迟，正数 = 晚出现（`sub-delay`）。**钳制由调用方（装配层）履行**。
    func setSubtitleDelay(_ seconds: Double) async

    func events() async -> AsyncStream<PlayerKernelEvent>
    func snapshot() async -> PlayerKernelSnapshot
}
