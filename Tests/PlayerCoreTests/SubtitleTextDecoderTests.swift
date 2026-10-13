import Foundation
import Testing
@testable import PlayerCore

@Suite
struct SubtitleTextDecoderTests {
    // MARK: - BOM：最强的信号，优先级最高

    @Test
    func testUTF8BOMIsDetectedAndStripped() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("中文字幕".utf8))

        let decoded = try #require(SubtitleTextDecoder.decode(data))

        #expect(decoded.encoding == .utf8WithBOM)
        #expect(decoded.text == "中文字幕")
        // ⚠️ BOM **必须被剥掉**：留着会让后面按行解析的第一行带上一个不可见字符，
        //    表现为"第一条字幕永远匹配不到时间轴"（极难查）。
        #expect(!decoded.text.hasPrefix("\u{FEFF}"))
    }

    /// ⚠️ 这一条**必须**断言完整相等（而不是"包含"）：BOM 是否被剥掉，差别正好落在第一个字符上。
    /// 实测：显式端序解码器**不吞** BOM（首码位会是 U+FEFF），所以这里的 `dropFirst(2)` 是**承重的**。
    @Test
    func testUTF16LittleEndianBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append("中文".data(using: .utf16LittleEndian)!)

        let decoded = try #require(SubtitleTextDecoder.decode(data))

        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(decoded.text == "中文")
    }

    @Test
    func testUTF16BigEndianBOM() throws {
        var data = Data([0xFE, 0xFF])
        data.append("中文".data(using: .utf16BigEndian)!)

        let decoded = try #require(SubtitleTextDecoder.decode(data))

        #expect(decoded.encoding == .utf16BigEndian)
        #expect(decoded.text == "中文")
    }

    // MARK: - ⚠️ 最阴的一条：UTF-16 的 ASCII 文本**同时是合法 UTF-8**

    /// `"AB".data(using: .utf16LittleEndian)` = `41 00 42 00` ——
    /// 这串字节**完全合法**的 UTF-8（NUL 是合法 UTF-8 码位）。
    /// 所以"先用 UTF-8 试解码"这个直觉做法会把 UTF-16 文件解成 `A\0B\0`，
    /// 即**看似成功、实则乱码**。必须先看 NUL 分布。
    @Test
    func testUTF16WithoutBOMIsNotMistakenForUTF8() throws {
        let data = "AB".data(using: .utf16LittleEndian)!

        let decoded = try #require(SubtitleTextDecoder.decode(data))

        #expect(decoded.encoding == .utf16LittleEndian, "必须靠 NUL 分布识破，而不是接受 UTF-8 的\"成功\"")
        #expect(decoded.text == "AB")
    }

    @Test
    func testUTF16WithoutBOMBigEndianVariant() throws {
        let data = "AB".data(using: .utf16BigEndian)!

        let decoded = try #require(SubtitleTextDecoder.decode(data))

        #expect(decoded.encoding == .utf16BigEndian)
        #expect(decoded.text == "AB")
    }

    // MARK: - 无 BOM 的 UTF-8

    @Test
    func testPlainUTF8IsDetected() throws {
        let decoded = try #require(SubtitleTextDecoder.decode(Data("你好，世界".utf8)))

        #expect(decoded.encoding == .utf8)
        #expect(decoded.text == "你好，世界")
    }

    @Test
    func testPureASCIIIsUTF8() throws {
        let decoded = try #require(SubtitleTextDecoder.decode(Data("1\n00:00:01,000 --> 00:00:02,000\nhello".utf8)))

        #expect(decoded.encoding == .utf8)
        #expect(decoded.text.contains("hello"))
    }

    // MARK: - GBK / GB18030 回退（G4 的「中文不乱码」主要指这条）

    /// 用**硬编码的真实 GBK 字节**，而不是"用自家编码器编一遍再解一遍"——
    /// 后者是自证循环：编码器和解码器同时错也能通过。
    /// `中` = `D6 D0`，`文` = `CE C4`（GBK 公认码位）。
    /// 顺带确认这串字节**不是**合法 UTF-8（`D0` 是前导字节却出现在续接位）⇒ 只能靠回退救。
    @Test
    func testGBKChineseFallsBackToGB18030() throws {
        #expect(String(data: Data([0xD6, 0xD0, 0xCE, 0xC4]), encoding: .utf8) == nil, "前置条件：它必须不是合法 UTF-8")

        let decoded = try #require(SubtitleTextDecoder.decode(Data([0xD6, 0xD0, 0xCE, 0xC4])))

        #expect(decoded.encoding == .gb18030)
        #expect(decoded.text == "中文")
    }

    @Test
    func testGBKSubtitleFileDecodesWholeDocument() throws {
        // 1\n00:00:01,000 --> 00:00:02,000\n中文 (GBK)
        var bytes = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        bytes.append(contentsOf: [0xD6, 0xD0, 0xCE, 0xC4])

        let decoded = try #require(SubtitleTextDecoder.decode(bytes))

        #expect(decoded.encoding == .gb18030)
        #expect(decoded.text.hasSuffix("中文"))
    }

    // MARK: - 解不出来就说解不出来，不许给乱码

    @Test
    func testUndecodableBytesReturnNilRatherThanMojibake() {
        // 0xFF / 0xFE 是 UTF-8 的非法字节；0xFF 也不是合法 GBK 前导后接单字节的组合。
        let data = Data(repeating: 0xFF, count: 8)

        #expect(SubtitleTextDecoder.decode(data) == nil, "宁可不显示，也不要显示乱码 —— 乱码是静默的失败")
    }

    @Test
    func testEmptyDataIsEmptyUTF8() throws {
        let decoded = try #require(SubtitleTextDecoder.decode(Data()))

        #expect(decoded.text.isEmpty)
    }

    // MARK: - 单一 NUL 不该被当成 UTF-16（阈值要经得起噪声）

    @Test
    func testSingleStrayNULDoesNotTriggerUTF16() throws {
        // 某个编辑器插了一个 NUL 的 UTF-8 文件：不能被判成 UTF-16 而整篇翻车。
        var data = Data("字幕".utf8)
        data.append(0x00)
        data.append(Data(" 尾巴".utf8))

        let decoded = try #require(SubtitleTextDecoder.decode(data))

        #expect(decoded.encoding == .utf8, "偶发 NUL 不足以证明是 UTF-16")
        #expect(decoded.text.contains("字幕"))
    }
}
