import Foundation

public enum SubtitleFormat: String, Sendable, CaseIterable {
    case srt
    case ass
    case ssa
}

public enum SubtitleParseError: Error, Equatable {
    /// 认不出编码。**明确报错，而不是给一串乱码。**
    case undecodableText
}

/// 统一入口：**字节 + 文件名 → 可直接查询的字幕内容**。
///
/// 把"解码"和"解析"合在这里，是为了让调用方（内核层 / 界面层）只需要关心一条路径；
/// 所有平台无关的判定都留在 `PlayerCore`，因而能被门禁的单测与变异覆盖。
public struct SubtitleDocument: Sendable, Equatable {
    public var format: SubtitleFormat
    public var cues: [SubtitleCue]
    public var styles: [ASSStyle]
    public var playResX: Int?
    public var playResY: Int?
    /// 被丢掉的坏块/坏事件数（两类格式语义相同：**看起来该有内容但没能解析出来的条数**）。
    public var skippedBlocks: Int
    /// 实际用什么编码解出来的（排查"乱码"时这是第一手证据）。
    public var decodedWith: SubtitleEncoding

    public init(
        format: SubtitleFormat,
        cues: [SubtitleCue] = [],
        styles: [ASSStyle] = [],
        playResX: Int? = nil,
        playResY: Int? = nil,
        skippedBlocks: Int = 0,
        decodedWith: SubtitleEncoding = .utf8
    ) {
        self.format = format
        self.cues = cues
        self.styles = styles
        self.playResX = playResX
        self.playResY = playResY
        self.skippedBlocks = skippedBlocks
        self.decodedWith = decodedWith
    }

    /// 建一条使用本文件内容的可查询时间线。
    public func timeline() -> SubtitleTimeline {
        SubtitleTimeline(cues: cues)
    }

    /// 格式判定：**先信扩展名，再让内容翻案**。
    ///
    /// 单靠扩展名不够 —— 用户下载来的文件里 `.srt` 装 ASS 的情况很常见；
    /// 单靠内容也不够 —— 一份纯文本的错误文件没有任何特征串。
    public static func detectFormat(fileName: String, text: String) -> SubtitleFormat {
        switch fileExtension(of: fileName) {
        case "srt": return .srt
        case "ass": return .ass
        case "ssa": return .ssa
        default: break
        }

        let lowered = text.lowercased()
        if lowered.contains("v4+ styles") { return .ass }
        if lowered.contains("v4 styles") { return .ssa }
        if lowered.contains("[script info]") { return .ass }
        return .srt
    }

    public static func parse(data: Data, fileName: String) throws -> SubtitleDocument {
        guard let decoded = SubtitleTextDecoder.decode(data) else {
            throw SubtitleParseError.undecodableText
        }
        let format = detectFormat(fileName: fileName, text: decoded.text)

        switch format {
        case .srt:
            let result = SRTParser.parse(decoded.text)
            return SubtitleDocument(
                format: .srt,
                cues: result.cues,
                skippedBlocks: result.skippedBlocks,
                decodedWith: decoded.encoding
            )
        case .ass, .ssa:
            let result = ASSParser.parse(decoded.text)
            return SubtitleDocument(
                format: format,
                cues: result.cues,
                styles: result.styles,
                playResX: result.playResX,
                playResY: result.playResY,
                skippedBlocks: result.skippedEvents,
                decodedWith: decoded.encoding
            )
        }
    }

    private static func fileExtension(of fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: ".") else { return "" }
        return String(fileName[fileName.index(after: dot)...]).lowercased()
    }
}
