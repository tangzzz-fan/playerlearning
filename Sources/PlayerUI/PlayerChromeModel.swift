import Foundation

/// 控制层的**显隐策略**（纯逻辑，无 UI 依赖 ⇒ 可被单测钉住）。
///
/// 存在的理由：播放器的控制层必须会自己让开画面，否则"画面"永远只有三分之二。
/// 但让开的时机有几条反直觉的规则，写成 `if` 分散在 View 里，第二次改就没人记得全：
///
/// 1. **暂停时不许自动隐藏** —— 用户暂停十次有九次是要操作（拖进度 / 换字幕）。
///    这时候把控制层收走，等于刚点完就跟他抢。
/// 2. **按住时不隐藏**（拖拽中 / 菜单开着）—— 手指还在滑块上，控制层当然不能走。
/// 3. **只有"正在播 + 没被按住 + 当前可见"才安排隐藏**。三条缺一不可：
///    少第一条 ⇒ 暂停时界面一空；少第二条 ⇒ 拖到一半控制层消失；少第三条 ⇒ 空转计时器。
public struct PlayerChromeModel: Equatable, Sendable {
    /// 控制层当前是否显示。首帧显示（否则一进来是一片黑，用户不知道该点哪）。
    public private(set) var isVisible = true

    /// 是否被"按住"（拖拽中 / 菜单打开）。按住期间**不自动隐藏**。
    public private(set) var holdsOpen = false

    /// 播放中多久没操作就自动隐藏。
    /// 4 秒是个折中：2 秒太急（还没看清就没了），8 秒太长（挡着画面）。
    public var autoHideInterval: Double

    public init(autoHideInterval: Double = 4) {
        self.autoHideInterval = autoHideInterval
    }

    /// 点击画面：显示 ↔ 隐藏。**这是"点击不好"最直接的解药** ——
    /// 用户点画面时期待有反应，什么都不发生就会被读成"界面卡了"。
    public mutating func toggle() {
        isVisible.toggle()
    }

    public mutating func show() {
        isVisible = true
    }

    /// 开始一次需要"按住"的交互（拖拽 / 打开菜单）。顺带把它显示出来 ——
    /// 用户能拖的前提是看得见它在哪。
    public mutating func beginHoldingOpen() {
        holdsOpen = true
        isVisible = true
    }

    public mutating func endHoldingOpen() {
        holdsOpen = false
    }

    /// 该不该安排自动隐藏。三条前提全满足才为真。
    public func shouldAutoHide(isPlaying: Bool) -> Bool {
        isVisible && isPlaying && !holdsOpen
    }

    /// 计时到点。返回**是否真的隐藏了**（`false` 说明前提不成立，调用方别再空转计时器）。
    @discardableResult
    public mutating func autoHide(isPlaying: Bool) -> Bool {
        guard shouldAutoHide(isPlaying: isPlaying) else { return false }
        isVisible = false
        return true
    }
}
