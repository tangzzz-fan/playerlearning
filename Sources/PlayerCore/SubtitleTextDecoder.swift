import Foundation

/// 识别出来的字幕文件编码。
public enum SubtitleEncoding: String, Sendable, CaseIterable {
    case utf8WithBOM = "UTF-8 BOM"
    case utf8 = "UTF-8"
    case utf16LittleEndian = "UTF-16LE"
    case utf16BigEndian = "UTF-16BE"
    case gb18030 = "GB18030"
}

public struct SubtitleDecodedText: Sendable, Equatable {
    public var text: String
    public var encoding: SubtitleEncoding

    public init(text: String, encoding: SubtitleEncoding) {
        self.text = text
        self.encoding = encoding
    }
}

/// 字幕字节 → 文本。
///
/// **为什么必须有这一步**（`G4` 的「SRT 中文不乱码」）：
/// 外挂字幕大多是用户从各处捡来的，编码五花八门 —— UTF-8 带/不带 BOM、UTF-16、GBK/GB18030。
/// 把编码交给播放内核去猜，猜错的后果是**静默的乱码**（不是崩溃，只是没人看得懂），
/// 而"看不懂的字幕"和"没有字幕"在用户眼里是同一件事。所以这一步自己控制，且可被单测钉住。
///
/// **探测顺序不是随便排的**，见下面每一步的注释。
public enum SubtitleTextDecoder {
    public static func decode(_ data: Data) -> SubtitleDecodedText? {
        if data.isEmpty {
            return SubtitleDecodedText(text: "", encoding: .utf8)
        }

        // ① BOM 是**最强信号**，没有任何启发式能推翻它。
        if let bom = decodeWithBOM(data) {
            return bom
        }

        // ② ⚠️ UTF-16 的判定必须在 UTF-8 **之前**。
        //    原因反直觉：`"AB"` 的 UTF-16LE 字节是 `41 00 42 00`，而 NUL 本身是合法 UTF-8，
        //    所以这串字节**能"成功"解成 UTF-8**（得到 `A\0B\0`）—— 成功、但全错。
        //    "先试 UTF-8，失败再试别的"这种直觉做法会在这里把 UTF-16 文件全毁掉。
        if let encoding = likelyUTF16(data), let decoded = decode(data, as: encoding) {
            return SubtitleDecodedText(text: decoded, encoding: encoding)
        }

        // ③ UTF-8：覆盖面最广，先试它。
        if let decoded = decode(data, as: .utf8) {
            return SubtitleDecodedText(text: decoded, encoding: .utf8)
        }

        // ④ 繁体/简体中文的老字幕几乎都是 GBK 系；GB18030 是它的超集（含全部 Unicode 码位）。
        if let decoded = decode(data, as: SubtitleEncoding.gb18030), !decoded.contains("\u{FFFD}") {
            return SubtitleDecodedText(text: decoded, encoding: .gb18030)
        }

        // ⑤ 认不出来就说认不出来。**宁可让调用方明确报错，也不要给一串乱码** ——
        //    乱码是最坏的结果：它看起来"有内容"，于是没人去查。
        return nil
    }

    // MARK: - BOM

    private static func decodeWithBOM(_ data: Data) -> SubtitleDecodedText? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            // ⚠️ 这里**不手工剥** BOM，因为 Foundation 解 UTF-8 时自己就会吞（20 行探针实测：
            //    `String(data: EF BB BF + "中", encoding: .utf8)` 首码位是 U+4E2D，不是 U+FEFF）。
            //    实测记在 `docs/PITFALLS` 的「等价变异体」一条里 —— 那条变异体永远杀不死，
            //    不是测试没写好，而是这行本来就等价。
            //    保留 `.utf8WithBOM` 这个标签仍然有用：它告诉排查的人"这份文件带 BOM"。
            guard let text = decode(data, as: .utf8) else { return nil }
            return SubtitleDecodedText(text: text, encoding: .utf8WithBOM)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            // ⚠️ 这两条**必须手工剥**：显式端序解码器**不吞 BOM**（实测首码位是 U+FEFF）。
            //    不剥的后果不是乱码，而是第一条字幕前多一个不可见字符 ——
            //    于是"首条字幕永远对不上时间轴"，且肉眼看不出来。
            guard let text = decode(Data(data.dropFirst(2)), as: .utf16LittleEndian) else { return nil }
            return SubtitleDecodedText(text: text, encoding: .utf16LittleEndian)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            guard let text = decode(Data(data.dropFirst(2)), as: .utf16BigEndian) else { return nil }
            return SubtitleDecodedText(text: text, encoding: .utf16BigEndian)
        }
        return nil
    }

    // MARK: - 无 BOM 的 UTF-16：靠 NUL 分布认

    /// ASCII 为主的文本在 UTF-16 下，每个字符都带一个 `0x00`。
    /// LE 的 `0x00` 落在**奇数**位（`41 00`），BE 落在**偶数**位（`00 41`）。
    ///
    /// ⚠️ 阈值刻意保守（**至少 2 个 NUL 且一侧占 3/4 以上**）：
    /// 某个编辑器在 UTF-8 文件里插了一个 NUL 是很常见的，
    /// 若"见到 NUL 就当 UTF-16"，这类文件会被整篇解错 —— 用一个偶发字节换掉整份文件，不划算。
    private static func likelyUTF16(_ data: Data) -> SubtitleEncoding? {
        var evenNuls = 0
        var oddNuls = 0
        var index = 0
        for byte in data {
            if byte == 0 {
                if index % 2 == 0 { evenNuls += 1 } else { oddNuls += 1 }
            }
            index += 1
        }
        let total = evenNuls + oddNuls
        guard total >= 2 else { return nil }
        if oddNuls * 4 >= total * 3 { return .utf16LittleEndian }
        if evenNuls * 4 >= total * 3 { return .utf16BigEndian }
        return nil
    }

    // MARK: - 编解码

    private static func decode(_ data: Data, as encoding: SubtitleEncoding) -> String? {
        String(data: data, encoding: stringEncoding(for: encoding))
    }

    private static func stringEncoding(for encoding: SubtitleEncoding) -> String.Encoding {
        switch encoding {
        case .utf8WithBOM, .utf8:
            .utf8
        case .utf16LittleEndian:
            .utf16LittleEndian
        case .utf16BigEndian:
            .utf16BigEndian
        case .gb18030:
            gb18030
        }
    }

    /// Foundation 没有 `.gbk` 常量，只能经 CoreFoundation 拿。
    /// 用 **GB18030** 而不是 GBK：前者是后者的超集（多出 GBK 未覆盖的少数汉字），
    /// 用超集去解老文件不会更差。
    private static let gb18030: String.Encoding = {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }()
}
