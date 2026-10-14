import Foundation
import Testing
@testable import PlayerCore
@testable import PlayerUI

/// 外挂字幕的**准备链路**：读 → 解编码 → 以 UTF-8 另存。
///
/// 这一条是 `G4` 里「SRT 中文不乱码」的**生产路径**证明 ——
/// 根包已经证明"GBK 字节能被正确解成中文"，这里证明"解出来的字符串被写成合法的 UTF-8 文件"。
/// 两段合起来，**乱码在结构上不可能出现**（不依赖内核猜对编码）。
@Suite
struct SubtitleLoaderTests {
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitle-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: [UInt8], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }

    private static let utf8SRT = """
    1
    00:00:01,000 --> 00:00:02,500
    第一句中文

    2
    00:00:03,000 --> 00:00:04,000
    第二句
    """

    @Test
    func testUTF8SubtitleIsCopiedAsUTF8() throws {
        let scratch = try makeScratch()
        let source = try write(Array(Self.utf8SRT.utf8), name: "utf8.srt")
        defer {
            try? FileManager.default.removeItem(at: source)
            SubtitleLoader.cleanUp(into: scratch)
        }

        let prepared = try SubtitleLoader.prepare(url: source, into: scratch)

        #expect(prepared.format == .srt)
        #expect(prepared.encoding == .utf8)
        #expect(prepared.cueCount == 2)
        #expect(prepared.skippedBlocks == 0)
        #expect(prepared.url != source, "交给内核的必须是我们自己目录里的副本，而不是用户选的文件")
        // ⚠️ 扩展名必须保留：内核按扩展名挑解析器，换成 .txt 会让 ASS 被当 SRT 解。
        #expect(prepared.url.pathExtension == "srt")
        #expect(try String(contentsOf: prepared.url, encoding: .utf8) == Self.utf8SRT)
    }

    /// **G4 的核心断言**：一份 GBK 的 SRT 进来，落地的必须是一份**合法 UTF-8、且中文正确**的文件。
    ///
    /// 用**硬编码的真实 GBK 字节**（`中` = `D6 D0`，`文` = `CE C4`）而不是"自己编一遍再解一遍"：
    /// 后者是自证循环，编解码同时错也能过。
    @Test
    func testGBKSubtitleBecomesValidUTF8() throws {
        let scratch = try makeScratch()
        let header = "1\n00:00:01,000 --> 00:00:02,500\n"
        var bytes = Array(header.utf8)
        bytes.append(contentsOf: [0xD6, 0xD0, 0xCE, 0xC4]) // 中文（GBK）
        let source = try write(bytes, name: "gbk.srt")
        defer {
            try? FileManager.default.removeItem(at: source)
            SubtitleLoader.cleanUp(into: scratch)
        }

        let prepared = try SubtitleLoader.prepare(url: source, into: scratch)

        #expect(prepared.encoding == .gb18030, "必须是靠编码探测救回来的，而不是碰巧解对")
        let raw = try Data(contentsOf: prepared.url)
        let text = try #require(String(data: raw, encoding: .utf8), "副本必须是**合法 UTF-8**")
        #expect(text.contains("中文"), "中文必须完好，实际内容：\(text)")
        #expect(!text.contains("\u{FFFD}"), "不许出现替换字符（那就是乱码）")
        #expect(prepared.cueCount == 1)
    }

    /// 认不出编码 ⇒ **明确报错**，绝不把乱码喂给内核
    /// （喂进去的症状是"字幕能开、但全是怪字"，比直接失败更难查）。
    @Test
    func testUndecodableSubtitleThrowsInsteadOfPassingGarbage() throws {
        let scratch = try makeScratch()
        let source = try write(Array(repeating: 0xFF, count: 32), name: "garbage.srt")
        defer {
            try? FileManager.default.removeItem(at: source)
            SubtitleLoader.cleanUp(into: scratch)
        }

        #expect(throws: SubtitleLoadError.undecodable) {
            _ = try SubtitleLoader.prepare(url: source, into: scratch)
        }
    }

    @Test
    func testASSKeepsItsExtensionAndStyles() throws {
        let scratch = try makeScratch()
        let ass = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1280

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,1,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,ASS 正文
        """
        let source = try write(Array(ass.utf8), name: "a.ass")
        defer {
            try? FileManager.default.removeItem(at: source)
            SubtitleLoader.cleanUp(into: scratch)
        }

        let prepared = try SubtitleLoader.prepare(url: source, into: scratch)

        #expect(prepared.format == .ass)
        #expect(prepared.url.pathExtension == "ass")
        #expect(prepared.cueCount == 1)
    }

    /// 换字幕不该留一堆文件 —— 用户按十次"载入字幕"就有十份副本，那是垃圾。
    @Test
    func testPreparingTwiceLeavesOnlyOneCopy() throws {
        let scratch = try makeScratch()
        let first = try write(Array(Self.utf8SRT.utf8), name: "one.srt")
        let second = try write(Array("1\n00:00:01,000 --> 00:00:02,000\n另一份\n".utf8), name: "two.srt")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            SubtitleLoader.cleanUp(into: scratch)
        }

        _ = try SubtitleLoader.prepare(url: first, into: scratch)
        _ = try SubtitleLoader.prepare(url: second, into: scratch)

        let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(contents.count == 1, "目录里应只剩最新那份，实际：\(contents)")
        #expect(contents.first == "two.srt")
    }

    @Test
    func testCleanUpRemovesDirectoryEntirely() throws {
        let scratch = try makeScratch()
        let source = try write(Array(Self.utf8SRT.utf8), name: "clean.srt")
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try SubtitleLoader.prepare(url: source, into: scratch)

        SubtitleLoader.cleanUp(into: scratch)

        #expect(!FileManager.default.fileExists(atPath: scratch.path),
                "连空目录一起收掉 —— 单测跑完不该在用户目录里留下东西")
    }
}
