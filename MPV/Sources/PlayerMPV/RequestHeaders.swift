import Foundation

/// 把 `PlayerResource.headers` 翻成 mpv 能吃的两种形态。
///
/// mpv 对请求头有**两个入口**：`user-agent` 选项与 `http-header-fields` 选项。
/// 不管的话，同一个 `User-Agent` 可能从两处各发一次，而"到底发了哪个"没人说得清 ——
/// CDN 按 UA 拒绝时，你会去查"UA 是不是写错了"，而真因是**两个来源在打架**。
/// 所以这里定死一条：**UA 单源**，只在 `user-agent` 里出现，从 `http-header-fields` 里剔除。
///
/// 排序也是刻意的：字典无序 ⇒ 不排序则每次生成的字符串顺序都不同，
/// 日志与断言都失去可比性（同一个配置，两次跑出来不一样，就没法判断"改坏了没有"）。
struct RequestHeaders: Equatable {
    let userAgent: String?
    let headerFields: String?

    init(_ headers: [String: String]) {
        let agentKey = headers.keys.first { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }
        userAgent = agentKey.flatMap { headers[$0] }

        let fields = headers
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ",")

        headerFields = fields.isEmpty ? nil : fields
    }
}
