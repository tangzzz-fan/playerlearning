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
    /// 选中某条**视频轨**（mpv 的 `vid`）—— 「可切清晰度」的抓手。
    ///
    /// ⚠️ 参数**非可选**，与字幕轨刻意不同：`vid=no` 等于**没有画面**，
    /// 那不是播放器可以停留的合法状态（HLS 多码率下切档也永远有档可切）。
    /// 让"关掉视频"在类型上就不可表达，比事后在实现里挡一下可靠。
    func selectVideoTrack(id: Int64) async
    /// 要不要显示字幕（`sub-visibility`）。
    func setSubtitleVisible(_ visible: Bool) async
    /// 字幕延迟，正数 = 晚出现（`sub-delay`）。**钳制由调用方（装配层）履行**。
    func setSubtitleDelay(_ seconds: Double) async

    func events() async -> AsyncStream<PlayerKernelEvent>
    func snapshot() async -> PlayerKernelSnapshot

    /// **可选能力**：转发内核自己的日志（诊断用）。
    ///
    /// 协议里**给默认实现**（什么都不做），而不是把它做成必需项：
    /// "能不能吐日志"是**内核特有的**（libmpv 用 `mpv_request_log_messages`，
    /// 别的内核机制完全不同）。做成必需项就会逼每个替代实现都写一个空方法 ——
    /// 那是**假装支持**。可选的语义应该是「不实现 = 不支持」，而不是「不实现 = 编译不过」。
    func enableLogging(_ handler: @escaping @Sendable (String) -> Void) async
}

public extension PlayerKernelProtocol {
    /// 默认：不支持内核日志。**静默 no-op**（调用方不该关心谁支持）。
    func enableLogging(_ handler: @escaping @Sendable (String) -> Void) async {}
}
