import Foundation

/// 视频输出的**两种结构**（不是两种参数，是两种结构）。
///
/// - `windowEmbed`：把宿主句柄（iOS 的 `wid`）交给播放器，帧**由播放器直接画到我们的图层**上。
///   我们拿不到像素 —— 自绘字幕 / 滤镜 / 全景 / 3D / 截图全都做不了（`docs/24` §一）。
/// - `renderAPI`：我们驱动渲染（`mpv_render_context_render`），帧**先落到我们手里**再上屏。
///   多一次拷贝，换来做任何后处理的能力。
public enum VideoOutputKind: Sendable, Equatable {
    case windowEmbed
    case renderAPI
}

public protocol VideoOutputProtocol {
    var windowEmbedHandle: Int64? { get }
}

public extension VideoOutputProtocol {
    /// **从能力推导，而不是另存一份声明**。
    ///
    /// 曾经的写法是让每个实现自己写一个 `kind` 常量 —— 那会出现"声明说是 renderAPI、
    /// 而句柄其实非空"这种自相矛盾，且没有任何地方会发现。
    /// 句柄是这条路上唯一的事实：**能给出句柄 ⇔ 帧在播放器内部**。
    var kind: VideoOutputKind {
        windowEmbedHandle == nil ? .renderAPI : .windowEmbed
    }
}
