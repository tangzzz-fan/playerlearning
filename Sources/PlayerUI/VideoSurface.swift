import QuartzCore

/// 能被 `PlayerSurfaceView` 挂上去、并且知道"自己该占哪一块"的图层。
///
/// 为什么要这一层抽象：项目里现在有**两种结构完全不同**的视频输出（`docs/24`）——
/// - `WindowEmbedOutput`：把帧交给播放器，帧由播放器画进这个图层；
/// - `MPVRenderOutput`：帧先到我们手里，**由我们自己**画进这个图层。
///
/// 对界面来说两者只差一件事：**谁来摆它**。把这一点收成协议，
/// `PlayerScreenView` / `PlayerSurfaceView` 就不必认识具体是哪种 ——
/// 否则每加一种输出，整条 UI 层都要跟着改一遍签名。
///
/// 继承 `CALayer` 而不是"随便一个 AnyObject"：宿主视图要做的是 `addSublayer`，
/// 那是 `CALayer` 的能力，泛化到 `AnyObject` 只会逼每个调用点再向下转型一次。
///
/// 协议本身**不标 `@MainActor`**：标了会让实现类型的**所有**协议一致性被推断成
/// 主线程隔离（实测报 `conformance … crosses into main actor-isolated code`，
/// 连 `VideoOutputProtocol` 都被牵连）。线程纪律放在各自的实现里写明。
public protocol VideoSurface: CALayer {
    /// 摆到宿主视图的 `bounds` 上，`scale` 是屏幕倍率（像素 = 逻辑点 × scale）。
    func layout(in bounds: CGRect, scale: CGFloat)
}
