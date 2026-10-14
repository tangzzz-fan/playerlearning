import Foundation

/// 样例视频的**来源**。必须如实记录：判定依赖"这份素材到底是什么"。
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
/// 为什么从"自造片段"改成"下载真实视频"：自造片段只能证"链路通了" ——
/// 它没有真实码流、没有真实音轨参数、没有真实容器结构，而这三样恰恰最容易出问题。
/// **用自造素材验证真实播放器，等于自己给自己出题。**
///
/// 候选是**实测**出来的（`AVURLAsset` 量的，不是估的）：
///
/// | 候选 | 时长 | 尺寸 | 音轨 | 体积 | 结论 |
/// | --- | --- | --- | --- | --- | --- |
/// | **`durian` Sintel trailer 720p** | **52.21 s** | **1280×720** | 48 kHz 立体声 | 7.3 MB | ✅ **选它** |
/// | `w3c` Sintel trailer | 52.21 s | 854×480 | 48 kHz 立体声 | 4.2 MB | ✅ 备用（同素材、另一域名） |
/// | `w3c` Big Buck Bunny trailer | 32.96 s | 853×480 | 48 kHz **6 声道** | 10.5 MB | ⚠️ 体积/声道都不划算 |
/// | `w3c/movie_300.mp4` | 300.04 s | **320×240** | 22 kHz 单声道 | 2.6 MB | ❌ 卡在 5 分钟边界，且画质太糊 |
/// | MDN `flower.mp4` | 5.01 s | 960×540 | 48 kHz 立体声 | 1.1 MB | ⚠️ 太短：只够证"能播" |
///
/// **为什么是 720p 而不是更小的 480p**：这不该只看流量。
/// 我们真正要看的是「**UI 叠加在画面上**」的效果 —— 字幕位置、控制层在明亮画面上可不可读、
/// 全屏时的缩放。320×240 那种画质看不出这些。**素材的用途决定了它的分辨率下限。**
///
/// ⚠️ 因此有两处**不许写死**（换素材就假红，见 `P-042`）：
/// **画面尺寸** · **音轨采样率** · **时长**。断言一律写成「非零 / 非空 / 有推进」。
///
/// 许可：Sintel 来自 Blender Foundation（**CC BY 3.0**），`flower.mp4` 来自 MDN 的 `cc0-videos`（**CC0**）。
/// 两者都**不随仓库分发** —— 运行时下载、缓存在 App 容器里。
enum SampleClipProvider {
    /// 候选地址，按优先级。任何一个成功即可。
    ///
    /// 三个都留着，理由是它们各挡一种失败：
    /// ① Blender 官方域（主源，画质最好）；② W3C 镜像（同素材、不同域名 —— 主域挂掉时仍可播）；
    /// ③ MDN 的 `flower`（**最短最小**，前两个都连不上时至少还能证"能播能出声"）。
    /// **样板工程不该因为一个域名失效就整体不可用。**
    static let candidateURLStrings = [
        "https://download.blender.org/durian/trailer/sintel_trailer-720p.mp4",
        "https://media.w3.org/2010/05/sintel/trailer.mp4",
        "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4",
    ]

    /// 下载失败时的兜底（本地生成）。它**仍然带一条真的 AAC 音轨**，所以「出声」这项不会因为离线而失去证据。
    static let fallbackSize = (width: SampleClipWriter.width, height: SampleClipWriter.height)

    /// 一份能播的视频至少这么大。**半个文件比没有文件更糟** ——
    /// 它"看起来成功"，然后在播放时才炸（`P-002` 记过被静默截断的下载）。
    static let minimumBytes = 64 * 1024

    enum Failure: Error {
        case unavailable
    }

    /// 保证有一份可播的样例。返回 `nil` 表示**下载与本地生成都失败**（调用方必须如实报出来）。
    ///
    /// 顺序：**缓存 → 下载（逐个候选）→ 本地生成**。
    /// 「缓存」放在最前不只是省流量 —— 它让反复运行的验证拿到**同一份**素材。
    static func ensureClip(overrideURL: String? = nil) async -> SampleClip? {
        let directory = cacheDirectory()

        var urls = candidateURLStrings
        if let overrideURL, !overrideURL.isEmpty {
            urls.insert(overrideURL, at: 0)
        }

        // ⚠️ 缓存要**按候选文件名精确匹配**，不能"目录里有任何文件就算命中"。
        //    后者是我第一版的写法，它有个真问题：换素材之后，**旧素材的缓存会一直挡住新素材**
        //    —— 改了候选列表却仍然播着上一个视频，而且看不出来（`source` 会如实说"缓存"）。
        for string in urls {
            guard let url = URL(string: string) else { continue }
            if let cached = cachedClip(for: url, in: directory) {
                return SampleClip(url: cached, source: .cached)
            }
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
    /// 它给"手动验证字幕"留了一条零操作的路：往样例目录里丢一个同名 `.srt` 就行。
    static func sidecarSubtitle(for clip: SampleClip) -> URL? {
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

    /// 这个 URL 对应的缓存是否已经存在且**像样**（够大）。
    private static func cachedClip(for url: URL, in directory: URL) -> URL? {
        let name = url.lastPathComponent
        guard !name.isEmpty else { return nil }
        let candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size >= minimumBytes ? candidate : nil
    }

    // MARK: - 下载

    private static func download(_ url: URL, into directory: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("PlayerLearningDemo/1.0", forHTTPHeaderField: "User-Agent")

        // ⚠️ 用 `download(for:)` 而不是 `data(for:)`：后者把**整个视频读进内存**。
        //    52 s 的 720p 是 7 MB，尚可忍；但素材一旦换成几分钟的片子，那就是几十上百 MB 常驻内存。
        //    「现在还能跑」不是把大文件读进内存的理由 —— 这类改动**换素材的那天才会暴露**。
        guard let (temporary, response) = try? await URLSession.shared.download(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) { return nil }

        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= minimumBytes else { return nil }

        let name = url.lastPathComponent.isEmpty ? "sample.mp4" : url.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 先清掉同名的坏缓存，再原子落盘。
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
