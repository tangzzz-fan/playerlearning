/// 音频链路状态：**解码端**采样率与**输出端**采样率。
///
/// 为什么分成两个字段而不是一个 Bool：
/// "有音轨"（解出了采样率）与"真的在出声"（音频输出已建立）**是两件事** ——
/// 只有后者才意味着声音进了输出设备。把两者混成一个"有声音"，就会在
/// "文件有音轨但没有音频输出设备"时撒谎。
///
/// 与 `VideoSizeTracker` 同一范式：**只在变化时**给出新值，避免无谓上报。
/// 本类型放在 `PlayerCore`（无 I/O、无 C 依赖）才能被门禁的单测与变异覆盖。
public struct PlayerAudioState: Sendable, Equatable {
    /// 解码端采样率；`0` 表示当前没有音频在解码。
    public private(set) var decoderSampleRate = 0
    /// 输出端采样率；`0` 表示音频输出尚未建立。
    public private(set) var outputSampleRate = 0

    public init() {}

    /// 有音频在解码（文件确实带音轨，且已被选中）。
    public var isDecoding: Bool { decoderSampleRate > 0 }

    /// 音频输出已建立 —— **这是"出声"在 API 层面能拿到的最强证据**。
    public var isOutputting: Bool { outputSampleRate > 0 }

    @discardableResult
    public mutating func setDecoderSampleRate(_ rate: Int) -> PlayerAudioState? {
        guard rate != decoderSampleRate else { return nil }
        decoderSampleRate = rate
        return self
    }

    @discardableResult
    public mutating func setOutputSampleRate(_ rate: Int) -> PlayerAudioState? {
        guard rate != outputSampleRate else { return nil }
        outputSampleRate = rate
        return self
    }
}
