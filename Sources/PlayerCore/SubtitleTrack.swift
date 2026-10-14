import Foundation

/// 一条字幕轨（内挂或外挂）。
///
/// 这是**跨层**的值类型：内核枚举出来、控制器持有、界面拿去画菜单。
public struct SubtitleTrack: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var title: String?
    public var language: String?
    public var isExternal: Bool
    public var codec: String?

    public init(
        id: Int64,
        title: String? = nil,
        language: String? = nil,
        isExternal: Bool = false,
        codec: String? = nil
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.isExternal = isExternal
        self.codec = codec
    }

    /// 界面上该显示的一行字。
    ///
    /// 三级回退（标题 → 语言 → 带序号的兜底）是刻意的：**两条无名轨在菜单里长得一模一样，
    /// 用户就没法选** —— 所以兜底必须带上 `id`，让它至少可区分。
    public var label: String {
        if let title, !title.isEmpty { return title }
        if let language, !language.isEmpty { return language }
        return isExternal ? "外挂字幕 #\(id)" : "字幕轨 #\(id)"
    }

    public var isForeign: Bool { isExternal }
}
