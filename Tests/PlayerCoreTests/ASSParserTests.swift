import Foundation
import Testing
@testable import PlayerCore

@Suite
struct ASSParserTests {
    /// 一份**贴近真实**的 ASS：`[V4+ Styles]` 与 `[Events]` 各自带 `Format:`，
    /// 台词里含逗号、含覆盖标签、含 `\N` 硬换行。
    private static let v4plus = """
    [Script Info]
    Title: 测试
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,思源黑体,64,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,2,1,2,20,20,30,1
    Style: 双语,思源黑体,48,&H00FFFF00,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,1,0,8,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.50,0:00:03.20,Default,,0,0,0,,{\\pos(960,900)}第一句，带逗号
    Dialogue: 0,0:00:04.00,0:00:06.00,双语,,0,0,0,,上\\N下
    Comment: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,这条是注释不该显示
    """

    @Test
    func testParsesScriptInfo() {
        let result = ASSParser.parse(Self.v4plus)

        #expect(result.playResX == 1920)
        #expect(result.playResY == 1080)
    }

    /// ⚠️ ASS 的时间是**厘秒**（`0:00:01.50` = 1.5 s），SRT 是**毫秒**。
    /// 把两者当同一个东西，字幕会整体跑偏 10 倍 —— 这条专治它。
    @Test
    func testTimeIsCentisecondsNotMilliseconds() {
        let result = ASSParser.parse(Self.v4plus)

        #expect(result.cues[0].start == 1.5)
        #expect(result.cues[0].end == 3.2)
    }

    @Test
    func testParsesStyles() throws {
        let result = ASSParser.parse(Self.v4plus)

        #expect(result.styles.count == 2)
        let def = try #require(result.styles.first { $0.name == "Default" })
        #expect(def.fontName == "思源黑体")
        #expect(def.fontSize == 64)
        #expect(def.alignment == 2)
        #expect(def.isBold, "`-1` 才是开，`0` 是关（ASS 用负数表示真）")
        #expect(def.marginVertical == 30)
    }

    @Test
    func testBoldIsFalseWhenZero() {
        let result = ASSParser.parse(Self.v4plus)

        let bilingual = result.styles.first { $0.name == "双语" }
        #expect(bilingual?.isBold == false)
        #expect(bilingual?.alignment == 8)
    }

    @Test
    func testParsesDialogueAndSkipsComments() {
        let result = ASSParser.parse(Self.v4plus)

        #expect(result.cues.count == 2, "`Comment:` 行不得变成字幕")
        #expect(result.skippedEvents == 0, "注释行是合法内容，不该计入跳过")
        #expect(result.cues[0].styleName == "Default")
        #expect(result.cues[1].styleName == "双语")
    }

    /// 台词是 `Format:` 的**最后一个字段**，而它**允许含逗号**（标点、歌唱、多语言）。
    /// 老老实实 `split(",")` 会把台词切碎 —— 这条就是那个经典 bug 的回归网。
    @Test
    func testCommasInsideDialogueTextArePreserved() {
        let result = ASSParser.parse(Self.v4plus)

        #expect(result.cues[0].text == "第一句，带逗号")
    }

    @Test
    func testOverrideTagsAreStripped() {
        let result = ASSParser.parse(Self.v4plus)

        #expect(!result.cues[0].text.contains("\\pos"), "覆盖标签是给 libass 看的，不该进纯文本")
        #expect(!result.cues[0].text.contains("{"))
    }

    @Test
    func testHardNewlineBecomesRealNewline() {
        let result = ASSParser.parse(Self.v4plus)

        #expect(result.cues[1].text == "上\n下", "`\\N` 是硬换行")
    }

    // MARK: - Format 行驱动解析（不假设字段顺序）

    /// 老 SSA（`[V4 Styles]` / `ScriptType: v4.00`）的字段集与顺序**和 V4+ 不一样**
    /// （`TertiaryColour` / `AlphaLevel`，`Events` 里是 `Marked` 而非 `Layer`）。
    /// 所以必须**按 `Format:` 行给出的名字**取字段，不能写死下标。
    @Test
    func testSSAv4FieldsAreMappedByNameNotByPosition() {
        let text = """
        [Script Info]
        ScriptType: v4.00

        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
        Style: Default,Arial,32,&HFFFFFF,&HFFFF00,&H000000,&H80000000,0,0,1,2,0,2,10,10,10,0,1

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:02.00,0:00:04.00,Default,,0,0,0,,老格式
        """

        let result = ASSParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.cues[0].start == 2.0)
        #expect(result.cues[0].text == "老格式")
        let style = result.styles.first
        #expect(style?.fontName == "Arial")
        #expect(style?.alignment == 2)
    }

    /// 少数文件干脆没有 `Format:` 行。此时退回**该节的默认字段序**（而不是放弃解析）。
    @Test
    func testMissingFormatLineFallsBackToStandardOrder() {
        let text = """
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,没有 Format 行
        """

        let result = ASSParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.cues[0].text == "没有 Format 行")
        #expect(result.cues[0].end == 2.0)
    }

    @Test
    func testMalformedDialogueIsCountedAsSkipped() {
        let text = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:XX.00,0:00:02.00,Default,,0,0,0,,坏时间
        Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,好的
        """

        let result = ASSParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.skippedEvents == 1)
    }

    @Test
    func testCuesAreSortedByStart() {
        let text = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,后
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,前
        """

        let result = ASSParser.parse(text)

        #expect(result.cues.map(\.text) == ["前", "后"])
    }

    /// `\h` 是"硬空格"（不折行），转成普通空格即可；`\n` 是软换行。
    @Test
    func testHardSpaceAndSoftNewlineAreNormalized() {
        let text = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,A\\hB\\nC
        """

        let result = ASSParser.parse(text)

        #expect(result.cues[0].text == "A B\nC")
    }

    @Test
    func testSectionHeadersWithSpacesAndCaseAreTolerated() {
        let text = """
        [script info]
        playresx: 1280

        [ events ]
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,大小写
        """

        let result = ASSParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.playResX == 1280)
    }

    @Test
    func testEmptyDocumentYieldsNothing() {
        let result = ASSParser.parse("")

        #expect(result.cues.isEmpty)
        #expect(result.styles.isEmpty)
        #expect(result.playResX == nil)
    }

    /// `[Fonts]` / `[Graphics]` 节里是 base64 之类的裸数据，绝不能当台词解析
    /// （那会把一大堆编码串变成"字幕"）。
    @Test
    func testFontsAndGraphicsSectionsAreIgnored() {
        let text = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,真的台词

        [Fonts]
        fontname: 思源黑体
        AAABBBBCCCCDDDD

        [Graphics]
        filename: logo.png
        """

        let result = ASSParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.cues[0].text == "真的台词")
    }
}
