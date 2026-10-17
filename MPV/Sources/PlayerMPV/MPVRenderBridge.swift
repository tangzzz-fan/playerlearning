#if os(iOS)
import Foundation
import Libmpv

/// 内核 ↔ 显示端之间的**单向交接点**。
///
/// ## 为什么需要它（而不是"把显示端对象传给内核"）
/// 显示端（`MPVRenderOutput`）是一个 `@MainActor` 的图层，而内核是一个 actor。
/// 直接把图层对象塞进 actor 的构造器，Swift 6 会（正确地）拒绝：
/// **`sending main actor-isolated 'output' to actor-isolated initializer`** ——
/// 那个对象之后会在两个隔离域里被同时使用。
///
/// 交接的东西其实只有**一个句柄**，而且方向是单向的：
/// 内核建好句柄 → 显示端取走 → 自己建渲染上下文。
/// 于是把它们之间唯一需要传递的东西抽成一个 `Sendable` 的小盒子：
/// 内核不认识图层，图层也不认识内核。
///
/// ## 时序（三条硬约束）
/// 1. `offer` 必须在 `mpv_initialize` **之后**（渲染上下文挂在已初始化的句柄上）；
/// 2. 建上下文必须在**主线程**，且此后每帧渲染也在主线程（`mpv_render_context_*` 的同一线程要求）
///    —— 所以是显示端在**自己的**每一拍里取句柄，而不是内核推过去；
/// 3. 渲染上下文必须在句柄销毁**之前**释放 —— 内核在 `shutdown()` 里先 `await detachDisplay()`。
public final class MPVRenderBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: OpaquePointer?
    private var attachAction: (@MainActor () throws -> Void)?
    private var detachAction: (@MainActor () async -> Void)?

    public init() {}

    /// 内核侧：把句柄放到交接点上（同步，任何线程都可调用）。
    public func offer(_ handle: OpaquePointer) {
        lock.withLock { pending = handle }
    }

    /// 显示端侧：取走句柄。**只有第一次会拿到** —— 上下文一辈子只建一次。
    public func take() -> MPVHandleBox? {
        lock.withLock {
            guard let pending else { return nil }
            self.pending = nil
            return MPVHandleBox(pending)
        }
    }

    /// 显示端侧：登记"建上下文"的动作（构造显示端时调用）。
    public func registerAttach(_ action: @escaping @MainActor () throws -> Void) {
        lock.withLock { attachAction = action }
    }

    /// 内核侧：**在 `loadfile` 之前**把渲染上下文建起来。
    ///
    /// 这一步**不能省、也不能延后**：mpv 打开 `vo=libmpv` 的时候要求渲染上下文**已经在**，
    /// 否则它直接报 `No render context set.` 并让整个文件加载失败
    /// （实测：`Error opening/initializing the selected video_out (--vo) device` → `state=failed`）。
    /// 换句话说，这条路上"帧的出口"必须在**第一帧解码之前**就存在。
    public func attachDisplay() async throws {
        let action = lock.withLock { attachAction }
        try await action?()
    }

    /// 显示端侧：登记"请断开"的动作（在主线程、构造显示端时调用）。
    public func registerDetach(_ action: @escaping @MainActor () async -> Void) {
        lock.withLock { detachAction = action }
    }

    /// 内核侧：让显示端先释放渲染上下文，再继续销毁句柄。
    public func detachDisplay() async {
        let action = lock.withLock { detachAction }
        await action?()
    }
}
#endif
