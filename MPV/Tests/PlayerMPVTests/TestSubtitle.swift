#if canImport(Libmpv)
import Foundation

/// 字幕夹具：**现场写一个真实字幕文件**（SRT / ASS）。
///
/// 与 `TestClip` 同一条纪律：不往仓库塞文件、不依赖网络、内容确定性。
/// 编码由调用方决定（`Data(contentsOf:)` 不解码），所以想造 GBK 也能造。
enum TestSubtitle {
    static let chineseSRT = """
    1
    00:00:00,000 --> 00:00:30,000
    中文字幕测试

    2
    00:00:30,000 --> 00:00:40,000
    第二句
    """

    /// 一份**带定位标签**的 ASS：`\pos` 是 libass 的特效路径，用来确认 ASS 走的是 libass 而不是被当 SRT 解。
    static let effectASS = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1280
    PlayResY: 720

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,1,1,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:30.00,Default,,0,0,0,,{\\pos(640,600)}ASS 特效字幕
    """

    /// 写一份字幕到临时目录。`name` 里带上 UUID 以免并行/重跑时互相覆盖。
    static func makeURL(_ contents: String, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitle-\(UUID().uuidString).\(ext)")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }
}
#endif
