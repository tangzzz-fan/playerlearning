import Foundation
import Testing
@testable import PlayerCore

@Suite
struct SRTParserTests {
    @Test
    func testParsesSimpleDocument() {
        let text = """
        1
        00:00:01,000 --> 00:00:03,000
        第一句

        2
        00:00:04,500 --> 00:00:06,000
        第二句
        """

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 2)
        #expect(result.skippedBlocks == 0)
        #expect(result.cues[0].start == 1.0)
        #expect(result.cues[0].end == 3.0)
        #expect(result.cues[0].text == "第一句")
        #expect(result.cues[1].start == 4.5)
        #expect(result.cues[1].end == 6.0)
        #expect(result.cues[1].text == "第二句")
    }

    /// 规范用逗号，但野外大量文件用点（也是 WebVTT 的写法）⇒ 两种都要吃。
    @Test
    func testAcceptsDotAsMillisecondSeparator() {
        let text = "1\n00:00:01.250 --> 00:00:02.750\nhi"

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.cues[0].start == 1.25)
        #expect(result.cues[0].end == 2.75)
    }

    @Test
    func testAcceptsCRLFLineEndings() {
        let text = "1\r\n00:00:01,000 --> 00:00:02,000\r\n甲\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n乙"

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 2)
        #expect(result.cues[0].text == "甲", "CRLF 不该把 \\r 留在文本里")
        #expect(result.cues[1].text == "乙")
    }

    @Test
    func testAcceptsOldMacLineEndings() {
        let text = "1\r00:00:01,000 --> 00:00:02,000\r甲\r\r2\r00:00:03,000 --> 00:00:04,000\r乙"

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 2)
    }

    /// 序号行**可以缺席**（部分工具生成的文件没有）。靠"找 `-->`"定位，而不是靠行号。
    @Test
    func testWorksWithoutIndexLines() {
        let text = """
        00:00:01,000 --> 00:00:03,000
        无序号

        00:00:04,000 --> 00:00:05,000
        也没有
        """

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 2)
        #expect(result.cues[0].text == "无序号")
    }

    @Test
    func testKeepsMultiLineCueText() {
        let text = "1\n00:00:01,000 --> 00:00:03,000\n第一行\n第二行"

        let result = SRTParser.parse(text)

        #expect(result.cues[0].text == "第一行\n第二行", "多行文本必须保留换行，否则双语字幕会糊成一行")
    }

    /// SRT 允许在结束时间后面跟摆放参数（`X1:` / `Y1:` …）。那些不是时间的一部分。
    @Test
    func testIgnoresTrailingPositionSettings() {
        let text = "1\n00:00:01,000 --> 00:00:03,000 X1:100 X2:200 Y1:300 Y2:400\n定位字幕"

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.cues[0].end == 3.0)
        #expect(result.cues[0].text == "定位字幕")
    }

    @Test
    func testAcceptsMissingMilliseconds() {
        let text = "1\n00:00:01 --> 00:00:03\n整秒"

        let result = SRTParser.parse(text)

        #expect(result.cues[0].start == 1.0)
        #expect(result.cues[0].end == 3.0)
    }

    @Test
    func testAcceptsTwoDigitMillisecondsByScaling() {
        let text = "1\n00:00:01,5 --> 00:00:02,25\n缩位"

        let result = SRTParser.parse(text)

        #expect(result.cues[0].start == 1.5, "`5` 应读作 500 ms（按位数缩放），而不是 5 ms")
        #expect(result.cues[0].end == 2.25)
    }

    // MARK: - 坏块的处理：**要么保留、要么计数，不许静默吞掉**

    @Test
    func testCountsMalformedTimecodeAsSkipped() {
        let text = """
        1
        00:00:0X,000 --> 00:00:03,000
        坏的

        2
        00:00:04,000 --> 00:00:05,000
        好的
        """

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.skippedBlocks == 1, "坏块必须被计数 —— 静默丢弃是「失败被优化掉」的又一变体")
    }

    @Test
    func testCountsReversedTimeRangeAsSkipped() {
        let text = "1\n00:00:05,000 --> 00:00:03,000\n时间反了"

        let result = SRTParser.parse(text)

        #expect(result.cues.isEmpty)
        #expect(result.skippedBlocks == 1)
    }

    @Test
    func testZeroLengthCueIsKept() {
        // 零长度不算"坏"：它合法，只是永远不显示（左闭右开的必然结果）。
        let text = "1\n00:00:05,000 --> 00:00:05,000\n闪一下"

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.skippedBlocks == 0)
    }

    /// 没有 `-->` 的块是**噪声**（`WEBVTT` 头、空行、注释），不是"坏字幕块"。
    /// 把它们计进 `skippedBlocks` 会让这个数字失去意义。
    @Test
    func testHeaderLikeNoiseIsNotCountedAsSkipped() {
        let text = """
        WEBVTT

        1
        00:00:01,000 --> 00:00:03,000
        正文
        """

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.skippedBlocks == 0, "`WEBVTT` 头不是坏字幕块")
    }

    @Test
    func testEmptyDocumentYieldsNothing() {
        let result = SRTParser.parse("")

        #expect(result.cues.isEmpty)
        #expect(result.skippedBlocks == 0)
    }

    // MARK: - 文本清洗

    @Test
    func testStripsTrailingWhitespacePerLine() {
        let text = "1\n00:00:01,000 --> 00:00:03,000\n行尾有空格   "

        let result = SRTParser.parse(text)

        #expect(result.cues[0].text == "行尾有空格")
    }

    @Test
    func testCuesAreSortedByStart() {
        let text = """
        2
        00:00:05,000 --> 00:00:06,000
        后

        1
        00:00:01,000 --> 00:00:02,000
        前
        """

        let result = SRTParser.parse(text)

        #expect(result.cues.map(\.text) == ["前", "后"], "输出必须已排序 —— 查询依赖有序不变量")
    }

    /// 文本里**合法地**含有 `-->` 的行不该被误判成时间码行。
    /// 判据是"整行像一个时间码"，不是"含箭头"。
    @Test
    func testTextLineContainingArrowIsNotTreatedAsTimecode() {
        let text = "1\n00:00:01,000 --> 00:00:03,000\nA --> B 是箭头"

        let result = SRTParser.parse(text)

        #expect(result.cues.count == 1)
        #expect(result.cues[0].text == "A --> B 是箭头")
        #expect(result.cues[0].end == 3.0)
    }
}
