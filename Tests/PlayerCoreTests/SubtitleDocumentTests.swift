import Foundation
import Testing
@testable import PlayerCore

@Suite
struct SubtitleDocumentTests {
    @Test
    func testFormatFromExtension() {
        #expect(SubtitleDocument.detectFormat(fileName: "movie.srt", text: "") == .srt)
        #expect(SubtitleDocument.detectFormat(fileName: "movie.ass", text: "") == .ass)
        #expect(SubtitleDocument.detectFormat(fileName: "movie.ssa", text: "") == .ssa)
        #expect(SubtitleDocument.detectFormat(fileName: "MOVIE.SRT", text: "") == .srt, "扩展名大小写不该影响")
    }

    /// 扩展名可能骗人（`.txt`、`.srt` 里装的是 ASS）。内容要能翻案。
    @Test
    func testFormatFromContentWhenExtensionIsNotConclusive() {
        #expect(SubtitleDocument.detectFormat(fileName: "movie.txt", text: "[Script Info]\nScriptType: v4.00+") == .ass)
        #expect(SubtitleDocument.detectFormat(fileName: "movie.txt", text: "1\n00:00:01,000 --> 00:00:02,000\nx") == .srt)
        #expect(SubtitleDocument.detectFormat(fileName: "movie.vtt", text: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx") == .srt)
    }

    /// 内容里出现 `[V4 Styles]` ⇒ SSA；`[V4+ Styles]` / `ScriptType: v4.00+` ⇒ ASS。
    @Test
    func testDistinguishesASSFromSSA() {
        #expect(SubtitleDocument.detectFormat(fileName: "x.txt", text: "[V4+ Styles]") == .ass)
        #expect(SubtitleDocument.detectFormat(fileName: "x.txt", text: "[V4 Styles]") == .ssa)
        #expect(SubtitleDocument.detectFormat(fileName: "x.ass", text: "[V4 Styles]") == .ass, "扩展名优先")
    }

    @Test
    func testUnknownContentFallsBackToSRT() {
        #expect(SubtitleDocument.detectFormat(fileName: "mystery", text: "随便什么") == .srt)
    }

    // MARK: - 端到端：字节 → 可查询的时间线

    @Test
    func testParsesSRTFromUTF8Bytes() throws {
        let bytes = Data("1\n00:00:01,000 --> 00:00:02,000\n中文没问题".utf8)

        let document = try SubtitleDocument.parse(data: bytes, fileName: "a.srt")

        #expect(document.format == .srt)
        #expect(document.decodedWith == .utf8)
        #expect(document.cues.first?.text == "中文没问题")
    }

    /// **G4 的「SRT 中文不乱码」在纯逻辑层的第一道证明**：
    /// 一份 GBK 的 SRT 进来，出来的必须是能查时间轴的正确文本。
    @Test
    func testParsesGBKEncodedSRT() throws {
        let header = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        var bytes = header
        bytes.append(contentsOf: [0xD6, 0xD0, 0xCE, 0xC4]) // 中文（GBK）

        let document = try SubtitleDocument.parse(data: bytes, fileName: "a.srt")

        #expect(document.decodedWith == .gb18030)
        #expect(document.cues.first?.text == "中文")

        let timeline = SubtitleTimeline(cues: document.cues)
        #expect(timeline.text(at: 1.5) == "中文")
    }

    @Test
    func testParsesASSIncludingStyles() throws {
        let text = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1280
        PlayResY: 720

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,1,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,ASS 正文
        """

        let document = try SubtitleDocument.parse(data: Data(text.utf8), fileName: "a.ass")

        #expect(document.format == .ass)
        #expect(document.styles.count == 1)
        #expect(document.playResX == 1280)
        #expect(document.cues.first?.text == "ASS 正文")
    }

    @Test
    func testUndecodableDataThrowsInsteadOfReturningMojibake() {
        let garbage = Data(repeating: 0xFF, count: 16)

        #expect(throws: SubtitleParseError.undecodableText) {
            _ = try SubtitleDocument.parse(data: garbage, fileName: "a.srt")
        }
    }

    /// BOM 会被剥掉，所以**第一条字幕仍在正确的时间轴上** ——
    /// 若不剥，第一行会带一个不可见字符，表现为"首条字幕永不出现"。
    @Test
    func testBOMDoesNotBreakTheFirstCue() throws {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("1\n00:00:01,000 --> 00:00:02,000\n首条".utf8))

        let document = try SubtitleDocument.parse(data: bytes, fileName: "a.srt")

        #expect(document.cues.count == 1)
        #expect(document.cues.first?.start == 1.0)
    }

    @Test
    func testEmptyFileYieldsEmptyDocument() throws {
        let document = try SubtitleDocument.parse(data: Data(), fileName: "a.srt")

        #expect(document.cues.isEmpty)
    }
}
