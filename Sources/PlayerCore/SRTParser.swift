import Foundation

public struct SRTParseResult: Sendable, Equatable {
    public var cues: [SubtitleCue]
    /// 看起来像字幕块、但时间码/区间不合法而被丢掉的块数。
    public var skippedBlocks: Int

    public init(cues: [SubtitleCue] = [], skippedBlocks: Int = 0) {
        self.cues = cues
        self.skippedBlocks = skippedBlocks
    }
}

/// SRT 解析。
///
/// 两条刻意选择的策略：
/// ① **按内容定位**，不按行号 —— 序号行可以缺席、可以错位、可以被工具重编号；
/// ② **坏块要计数**，不静默丢弃 —— 静默丢弃是"失败被优化掉"的又一变体（`P-035` 同族）。
///
/// 顺带能吃下 WebVTT 的常见形态（`WEBVTT` 头 + 同一种时间码），代价只是忽略那个头。
public enum SRTParser {
    public static func parse(_ text: String) -> SRTParseResult {
        var cues: [SubtitleCue] = []
        var skipped = 0

        for block in blocks(in: text) {
            let lines = block.components(separatedBy: "\n")
            // 判据分两层，这是 `skippedBlocks` 能准确的原因：
            //   ① "这一块**看起来**是字幕块吗" → 看有没有 `-->`；没有就是噪声（`WEBVTT` 头、残留空行）
            //   ② "这一块**解析得动**吗"     → 时间码与区间是否合法；不合法才计 skipped
            // 若两层合成一层（"时间码合法才算字幕块"），坏块会全部落进"噪声"，
            // 于是 `skippedBlocks` 永远是 0 —— 一个看起来在工作、实际从不触发的计数器。
            guard let timecodeLine = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            guard let range = timeRange(lines[timecodeLine]), range.end >= range.start else {
                skipped += 1
                continue
            }
            cues.append(
                SubtitleCue(
                    start: range.start,
                    end: range.end,
                    text: cleanText(lines[(timecodeLine + 1)...])
                )
            )
        }

        return SRTParseResult(cues: sorted(cues), skippedBlocks: skipped)
    }

    // MARK: - 分块

    private static func blocks(in text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n")
    }

    private static func sorted(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.sorted { left, right in
            left.start == right.start ? left.end < right.end : left.start < right.start
        }
    }

    // MARK: - 时间码

    /// 整行**像一个时间码**才算 —— 而不是"含 `-->`"。
    /// 台词里出现箭头（`A --> B`）是常见的，用一个"含箭头"的判据会把台词行当时间码，
    /// 结果既丢字幕又把台词当时间解析失败，两个错误叠在一起。
    private static func timeRange(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let start = parseTimecode(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        // 结束时间后面可能跟摆放参数（`X1:` / `Y1:` …）⇒ 只取第一个词。
        let tail = parts[1].trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = tail.first, let end = parseTimecode(String(first)) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`（也接受 `.` 与两位/一位毫秒）。
    ///
    /// 全程按**整数毫秒**算再除回秒：直接 `秒 + 毫秒/1000` 会引入浮点误差，
    /// 而这条时间轴要与内核的 PTS 做相等/边界断言，差 1e-16 就足以让边界用例假红。
    static func parseTimecode(_ raw: String) -> Double? {
        // 逗号与点在这里等价（逗号是 SRT 规范，点是 WebVTT 写法）。
        let groups = raw.replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard groups.count == 3 else { return nil }
        guard let hours = Double(groups[0]), let minutes = Double(groups[1]) else { return nil }
        guard hours >= 0, minutes >= 0 else { return nil }

        let secondParts = groups[2].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let seconds = Double(secondParts[0]), seconds >= 0 else { return nil }

        var milliseconds = (hours * 3600 + minutes * 60 + seconds) * 1000
        if secondParts.count == 2 {
            guard let fraction = millisecondsFromFraction(secondParts[1]) else { return nil }
            milliseconds += fraction
        } else if secondParts.count > 2 {
            return nil
        }
        return milliseconds / 1000
    }

    /// `"500"` → 500、`"5"` → 500、`"25"` → 250、`"1234"` → 123。
    ///
    /// 按**位数缩放**而不是当整数读：`00:00:01,5` 在野外是 1.5 秒（不是 1.005 秒）。
    /// 超长就截断（`1234` 只可能来自错误的生成器，取前三位是最少惊讶的选择）。
    private static func millisecondsFromFraction(_ digits: String) -> Double? {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let padded = digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
        return Double(padded)
    }

    // MARK: - 文本

    private static func cleanText(_ lines: ArraySlice<String>) -> String {
        let cleaned = lines.map { line -> String in
            var trimmed = Substring(line)
            while let last = trimmed.last, last == " " || last == "\t" {
                trimmed = trimmed.dropLast()
            }
            return String(trimmed)
        }
        return cleaned.joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }
}
