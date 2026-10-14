import Foundation
import PlayerCore
import UniformTypeIdentifiers

public struct PreparedSubtitle: Sendable {
    /// **该交给内核的** URL（我们自己的 UTF-8 副本，不是用户选的那个）。
    public var url: URL
    /// 用户选的原文件（只用于显示与排查）。
    public var source: URL
    public var format: SubtitleFormat
    public var encoding: SubtitleEncoding
    public var cueCount: Int
    public var skippedBlocks: Int

    /// 给界面看的一行字 —— 把「什么编码 / 什么格式 / 丢了几块」如实说出来。
    public var summary: String {
        var text = "\(format.rawValue.uppercased()) · \(encoding.rawValue) · \(cueCount) 条"
        if skippedBlocks > 0 { text += " · 跳过 \(skippedBlocks) 块" }
        return text
    }
}

public enum SubtitleLoadError: Error, Equatable {
    case unreadable
    /// 认不出编码。**明确报错，而不是把乱码喂给内核**（那会变成"字幕能开但全是怪字"）。
    case undecodable
}

/// 外挂字幕的准备：**读进来 → 解对编码 → 以 UTF-8 另存一份 → 交给内核**。
///
/// 为什么坚持"另存一份"而不是把用户选的路径直接给内核：
///
/// ① **编码**：内核的编码探测不保证对（尤其 GBK 中文）。我们已经有 `SubtitleTextDecoder`
///    并且被单测钉住，用它解好再写 UTF-8，**"中文不乱码"就从"但愿"变成"结构上不可能错"**。
/// ② **生命周期**：`fileImporter` 给的是**沙盒外**的 URL。转存到我们自己目录里，
///    就不必在播放期间一直持有 security scope（持有久了会泄漏，放开早了内核读不到 ——
///    两头都是坑，索性绕开）。这与 `PlayerSecurityScopedAccess` 的取舍不同：
///    视频文件动辄数百 MB 不能复制，字幕只有几十 KB，复制代价可以忽略。
public enum SubtitleLoader {
    /// 文件选择器里允许出现的类型。
    ///
    /// ⚠️ 不能只给"字幕类型"：野外的 `.srt` 常被打成 `public.plain-text`，
    /// 那样用户在选择器里**根本看不到自己的字幕文件**（这比报错更难查 —— 看起来像 App 坏了）。
    /// 所以带上文本类兜底。`public.subtitle` 用标识串构造，因为 SDK 里没有 `UTType.subtitle` 成员。
    public static var allowedContentTypes: [UTType] {
        var types: [UTType] = []
        if let subtitle = UTType("public.subtitle") { types.append(subtitle) }
        types.append(contentsOf: [.plainText, .text])
        return types
    }

    /// 我们自己的字幕目录（与样例视频分开，便于整体清理）。
    public static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Subtitles", isDirectory: true)
    }

    /// - Parameter directory: 落地目录。`nil` = 用 App 容器里的默认位置。
    ///   ⚠️ **必须可注入**：macOS 上 `.documentDirectory` 指向用户的 `~/Documents` ——
    ///   单测若不可注入就会往那儿写文件（本机被测试污染是很难查的那类问题）。
    public static func prepare(url: URL, into destination: URL? = nil) throws -> PreparedSubtitle {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw SubtitleLoadError.unreadable }

        let document: SubtitleDocument
        do {
            document = try SubtitleDocument.parse(data: data, fileName: url.lastPathComponent)
        } catch {
            throw SubtitleLoadError.undecodable
        }

        let directory = destination ?? self.directory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 清掉上一份，避免每换一次字幕就留一个文件。
        removeAll(in: directory)

        // ⚠️ **保留扩展名**：内核按扩展名挑解析器（`.srt` / `.ass` / `.ssa`）。
        //    换成 `.txt` 会让它把 ASS 当 SRT 解，症状是"字幕时有时无"。
        let name = url.lastPathComponent.isEmpty ? "subtitle.srt" : url.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        let normalized = Data(document.text.utf8)
        // 原子写：半份字幕比没有字幕更糟（`P-002` 记过被静默截断的下载）。
        try normalized.write(to: destination, options: .atomic)

        return PreparedSubtitle(
            url: destination,
            source: url,
            format: document.format,
            encoding: document.decodedWith,
            cueCount: document.cues.count,
            skippedBlocks: document.skippedBlocks
        )
    }

    /// 退出播放器时清掉副本。不留在磁盘上，是为了"下次进来看不到上次的字幕"——
    /// 那种残留会让人以为字幕是自己冒出来的。
    public static func cleanUp(into destination: URL? = nil) {
        let directory = destination ?? self.directory()
        removeAll(in: directory)
        // 连空目录也收掉：留下一堆空目录同样属于"痕迹"，而且单测跑完不该在用户目录里留东西。
        try? FileManager.default.removeItem(at: directory)
    }

    private static func removeAll(in directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
