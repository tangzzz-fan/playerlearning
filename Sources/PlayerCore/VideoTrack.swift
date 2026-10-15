import Foundation

/// 一条**视频轨**的只读描述。
///
/// 为什么需要这个类型（而不是把清晰度另造一套模型）：
/// **HLS 的多码率档位在 mpv 里就是若干条 `type=video` 的普通轨道**（实测见 `docs/14`）——
/// 三档 720p/480p/240p 得到 `track-list/count = 6`（3 视频 + 3 音频），
/// 切换抓手就是 `vid`。所以「可切清晰度」= **视频轨道枚举 + 切换**。
///
/// 与 `SubtitleTrack` 的形状相似，但**有两处刻意的不同**：
/// ① 没有 `isExternal` —— 「外挂视频轨」这件事不存在；
/// ② **没有"关掉"** —— mpv 的 `vid=no` 等于没画面，不是合法状态。
///    ⇒ 选择接口收的是**非可选**的 id（见 `PlayerKernelProtocol.selectVideoTrack`）。
public struct VideoTrack: Sendable, Equatable, Identifiable {
    /// mpv 的轨道 id —— `vid` 用的就是它。
    public var id: Int64
    /// 容器里声明的分辨率（mpv 的 `track-list/N/demux-w` / `demux-h`）。
    ///
    /// ⚠️ 用 `demux-*` 而**不是** `video-params/*`：后者只描述**当前正在解的那一条**，
    /// 拿它当"每条轨的分辨率"读出来全会是同一个值。
    public var width: Int
    public var height: Int
    public var codec: String?
    /// 轨道的名义码率（**bit/s**，mpv 的 `track-list/N/demux-bitrate`）。
    ///
    /// 内核读不到时为 `nil` —— 实测 HLS 源上 mpv 的 `hls-bitrate` 属性**读不到**
    /// （`docs/14` §1.2），所以**不能把"档位信息"只押在码率上**：
    /// 分辨率才是可靠的那一项，码率是"有就显示"的补充。
    public var bitrate: Int?

    public init(
        id: Int64,
        width: Int,
        height: Int,
        codec: String? = nil,
        bitrate: Int? = nil
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.codec = codec
        self.bitrate = bitrate
    }

    /// 界面上该显示的一行字 —— **以分辨率为主**，码率作补充。
    ///
    /// 分辨率是唯一在实测里**稳定可得**的档位区分（`docs/14` §1.2 的 `demux=1280x720` 等）。
    /// ⚠️ 已知取舍：同一个源若**两档分辨率完全相同、而码率又读不到**，
    /// 两条的 `label` 就会一样（用户没法从文字上区分）。
    /// 这在标准 HLS 阶梯里不会出现（各档分辨率不同），故先不引入序号 ——
    /// 真遇到了再加，而不是先猜一个。分辨率也读不到时才退回带 id 的兜底。
    public var label: String {
        guard width > 0, height > 0 else { return "视频轨 #\(id)" }
        let resolution = "\(width)×\(height)"
        guard let bitrate, bitrate > 0 else { return resolution }
        return "\(resolution) · \(Self.rateLabel(bitrate))"
    }

    /// `2284533` → `"2.3 Mbps"`。**保留一位小数**：档位之间的差距远大于 0.1 Mbps，
    /// 多给位数只会让菜单里的文字更长。
    static func rateLabel(_ bitsPerSecond: Int) -> String {
        let megabits = Double(bitsPerSecond) / 1_000_000
        return String(format: "%.1f Mbps", megabits)
    }
}
