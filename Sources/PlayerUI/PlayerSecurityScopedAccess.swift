import Foundation

/// 安全作用域资源的访问记账。
///
/// 为什么值得单独一个类型：`.fileImporter` 交回来的 URL 指向**沙盒之外**
/// （"文件" App 里的文件），必须 `startAccessingSecurityScopedResource()` 才能读；
/// 而**漏掉对应的 stop 会泄漏**，这正是 iOS 上很难查的一类 bug。
/// 更阴的是 —— **不能拿到手就 stop**：mpv 是边播边按路径读，stop 早了播放中途会断。
///
/// 所以规则是：**访问权跟随"当前加载的文件"**，换文件时才释放上一个。
/// 类型负责记账并**明确告诉调用方"该 stop 哪一个"**（返回值就是契约），
/// 于是这段时序可以被单测与变异覆盖，而不是散在视图的回调里。
public struct PlayerSecurityScopedAccess: Sendable, Equatable {
    public private(set) var active: URL?

    public init() {}

    /// 开始访问 `url`，返回**需要停止访问**的旧 URL（`nil` 表示没有要停的）。
    ///
    /// - 同一个 URL 重复调用**不会重复 start**（重复 start 会让 stop 计数对不上）。
    public mutating func begin(_ url: URL) -> URL? {
        guard active != url else { return nil }
        let previous = active
        active = url
        _ = url.startAccessingSecurityScopedResource()
        return previous
    }

    /// 结束访问，返回**需要停止访问**的 URL（`nil` 表示本来就没在访问）。
    public mutating func end() -> URL? {
        let previous = active
        active = nil
        return previous
    }
}
