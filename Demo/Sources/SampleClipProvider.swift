import Foundation

/// 样例视频的**来源**。必须如实记录：`G2` 的判定依赖"这份素材到底是什么"。
enum SampleSource: String, Sendable {
    case cached = "缓存"
    case downloaded = "网络下载"
    case generated = "本地生成（离线兜底）"
}

struct SampleClip: Sendable {
    var url: URL
    var source: SampleSource
}

/// 样例视频：**优先真实视频**（网络下载 + 缓存），离线时退回本地生成。
///
/// 为什么从"自造片段"改成"下载真实视频"（2026-10-14 董事长要求）：
/// 自造片段只能证"链路通了" —— 它没有真实码流、没有真实音轨参数、没有真实容器结构，
/// 而这三样恰恰是最容易出问题的地方。**用自造素材验证真实播放器，等于自己给自己出题。**
///
/// 候选是**实测**出来的（`AVURLAsset` 量，不是估的）：
///
/// | 候选 | 时长 | 尺寸 | 音轨 | 结论 |
/// | --- | --- | --- | --- | --- |
/// | Big Buck Bunny 360p 10 s | 10.00 s | 640×360 | **0** | ❌ 无音轨 ⇒ `G2` 的「出声」无从证 |
/// | **MDN `flower.mp4`** | **5.01 s** | **960×540** | 1（48 kHz 立体声） | ✅ **选它**（CC0 · 1.1 MB） |
/// | Sintel trailer | 52.21 s | 854×480 | 1 | ⚠️ 太长：`G2` 等 `.finished` 是有上限的 |
///
/// ⚠️ 因此有三处**不许写死**（真实视频与自造片段的参数不同，写死必然假红）：
/// **画面尺寸**（960×540 vs 640×360）· **音轨采样率**（48000 vs 44100）· **时长**。
/// 断言一律改成「非零 / 非空 / 有推进」。
///
/// 许可：`flower.mp4` 来自 MDN 的 `cc0-videos` 目录（**CC0**，可自由使用），
/// 且**不随仓库分发** —— 运行时下载、缓存在 App 容器里。
enum SampleClipProvider {
    /// 候选地址，按优先级。任何一个成功即可。
    ///
    /// 第一个是 MDN 的旧域（`interactive-examples`），第二个是它迁移后的新域。
    /// 两个都留着是因为这类示例站点搬迁过，而**样板工程不该因为一个域名失效就整体不可用**。
    static let candidateURLStrings = [
        "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4",
        "https://mdn.github.io/shared-assets/videos/flower.mp4",
    ]

    /// 下载失败时的兜底（本地生成）。它**仍然带一条真的 AAC 音轨**，所以「出声」这项不会因为离线而失去证据。
    static let fallbackSize = (width: SampleClipWriter.width, height: SampleClipWriter.height)

    enum Failure: Error {
        case unavailable
    }

    /// 保证有一份可播的样例。返回 `nil` 表示**下载与本地生成都失败**（调用方必须如实报出来）。
    ///
    /// 顺序：**缓存 → 下载 → 本地生成**。
    /// 「缓存」放在最前不只是省流量 —— 它让反复运行的端到端测试拿到**同一份**素材。
    static func ensureClip(overrideURL: String? = nil) async -> SampleClip? {
        let directory = cacheDirectory()
        if let cached = existingClip(in: directory) {
            return SampleClip(url: cached, source: .cached)
        }

        var urls = candidateURLStrings
        if let overrideURL, !overrideURL.isEmpty {
            urls.insert(overrideURL, at: 0)
        }
        for string in urls {
            guard let url = URL(string: string) else { continue }
            if let saved = await download(url, into: directory) {
                return SampleClip(url: saved, source: .downloaded)
            }
        }

        guard let generated = try? await SampleClipWriter.ensureClip() else { return nil }
        return SampleClip(url: generated, source: .generated)
    }

    /// 与样例视频**同名**的字幕文件（sidecar）。
    ///
    /// 这是播放器行业的通行约定：`flower.mp4` 旁边的 `flower.srt` / `flower.ass` 自动可用。
    /// 它给"手动验证字幕"留了一条零操作的路：往样例目录里丢一个 `flower.srt` 就行。
    public static func sidecarSubtitle(for clip: SampleClip) -> URL? {
        let base = clip.url.deletingPathExtension()
        for ext in ["srt", "ass", "ssa"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - 缓存

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Samples", isDirectory: true)
    }

    /// 目录里任何一个**像样**的文件都算缓存命中（`> 4 KB`：半个文件不算）。
    private static func existingClip(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 4096 { return url }
        }
        return nil
    }

    // MARK: - 下载

    private static func download(_ url: URL, into directory: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("PlayerLearningDemo/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) { return nil }
        // 半个文件比没有文件更糟：它会"看起来成功"，然后在播放时才炸（`P-002` 记过被静默截断的下载）。
        guard data.count > 4096 else { return nil }

        let name = url.lastPathComponent.isEmpty ? "sample.mp4" : url.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }
}
