import Foundation

/// ASS / SSA 的样式表条目。
///
/// 只保留**能用得上**的那些字段：字幕渲染本身交给 libass（`P4-T3` 的决策），
/// 我们解析样式是为了"看得见、说得清"，以及日后的自绘路径有个起点。
public struct ASSStyle: Sendable, Equatable {
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var primaryColour: String
    public var alignment: Int
    public var marginLeft: Int
    public var marginRight: Int
    public var marginVertical: Int
    public var isBold: Bool
    public var isItalic: Bool

    public init(
        name: String,
        fontName: String = "",
        fontSize: Double = 0,
        primaryColour: String = "",
        alignment: Int = 0,
        marginLeft: Int = 0,
        marginRight: Int = 0,
        marginVertical: Int = 0,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.primaryColour = primaryColour
        self.alignment = alignment
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.marginVertical = marginVertical
        self.isBold = isBold
        self.isItalic = isItalic
    }
}

public struct ASSParseResult: Sendable, Equatable {
    public var cues: [SubtitleCue]
    public var styles: [ASSStyle]
    public var playResX: Int?
    public var playResY: Int?
    /// 看着像 `Dialogue:` 但时间/字段不合法而被丢掉的条数。
    public var skippedEvents: Int

    public init(
        cues: [SubtitleCue] = [],
        styles: [ASSStyle] = [],
        playResX: Int? = nil,
        playResY: Int? = nil,
        skippedEvents: Int = 0
    ) {
        self.cues = cues
        self.styles = styles
        self.playResX = playResX
        self.playResY = playResY
        self.skippedEvents = skippedEvents
    }
}

/// ASS / SSA 解析。
///
/// 三条来自真实文件的规则（每一条都有对应的单测与变异体）：
///
/// ① **按 `Format:` 行给出的字段名取值，不写死下标。**
///    `[V4+ Styles]` 与老 `[V4 Styles]` 的字段集和顺序都不一样（老格式有 `TertiaryColour` / `AlphaLevel`，
///    `Events` 里用 `Marked` 而不是 `Layer`）。写死下标在 V4+ 上看起来对，遇到老文件就整片错位。
/// ② **时间是厘秒**（`0:00:01.50` = 1.5 s），SRT 是毫秒。混了会让整条字幕跑偏 10 倍。
/// ③ **台词是最后一个字段且允许含逗号**（标点、歌唱、多语言）。`split(",")` 会把台词切碎 ——
///    这是字幕解析里的经典 bug，且症状是"只有带逗号的句子会被截断"，很容易被当成偶发。
public enum ASSParser {
    private static let defaultEventFields = [
        "layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text",
    ]

    private static let defaultStyleFields = [
        "name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour",
        "backcolour", "bold", "italic", "underline", "strikeout", "scalex", "scaley", "spacing",
        "angle", "borderstyle", "outline", "shadow", "alignment", "marginl", "marginr", "marginv",
        "encoding",
    ]

    public static func parse(_ text: String) -> ASSParseResult {
        var cues: [SubtitleCue] = []
        var styles: [ASSStyle] = []
        var playResX: Int?
        var playResY: Int?
        var skipped = 0

        var section = ""
        var eventFields = defaultEventFields
        var styleFields = defaultStyleFields

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                // `Format:` 是**节内**声明 ⇒ 换节要回到该节默认序，否则上一节的自定义序会漏进来。
                if section.contains("events") { eventFields = defaultEventFields }
                if section.contains("styles") { styleFields = defaultStyleFields }
                continue
            }

            let (key, value) = splitKeyValue(line)
            switch section {
            case "script info":
                if key == "playresx" { playResX = Int(value) }
                if key == "playresy" { playResY = Int(value) }

            case "events":
                if key == "format" {
                    eventFields = fieldNames(value)
                } else if key == "dialogue" {
                    if let cue = makeCue(value, fields: eventFields) {
                        cues.append(cue)
                    } else {
                        skipped += 1
                    }
                }

            case "v4+ styles", "v4 styles", "v4++ styles":
                if key == "format" {
                    styleFields = fieldNames(value)
                } else if key == "style" {
                    if let style = makeStyle(value, fields: styleFields) {
                        styles.append(style)
                    }
                }

            default:
                break
            }
        }

        return ASSParseResult(
            cues: cues.sorted { left, right in
                left.start == right.start ? left.end < right.end : left.start < right.start
            },
            styles: styles,
            playResX: playResX,
            playResY: playResY,
            skippedEvents: skipped
        )
    }

    // MARK: - 行内取键值

    /// `Dialogue: 0,0:00:01.50,…` → `("dialogue", "0,0:00:01.50,…")`
    /// （只看**第一个**冒号，否则时间码里的冒号会把键切坏）。
    private static func splitKeyValue(_ line: String) -> (key: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line.lowercased(), "")
        }
        let key = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func fieldNames(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    // MARK: - 字段切分

    /// 只按前 `count - 1` 个逗号切 —— **最后一个字段吞下剩余全部**。
    ///
    /// 这正是"台词含逗号"能活下来的原因：台词恒为最后一个字段，
    /// 于是它里面的逗号永远不会被当作分隔符。`Style` 行同理（末字段 `Fontname` 也可能含逗号）。
    static func splitFields(_ value: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var fields: [String] = []
        var current = ""
        for character in value {
            if character == ",", fields.count < count - 1 {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func fieldMap(_ value: String, fields: [String]) -> [String: String] {
        let parts = splitFields(value, count: fields.count)
        var map: [String: String] = [:]
        for (index, name) in fields.enumerated() where index < parts.count {
            map[name] = parts[index]
        }
        return map
    }

    // MARK: - 事件 → cue

    private static func makeCue(_ value: String, fields: [String]) -> SubtitleCue? {
        let map = fieldMap(value, fields: fields)
        guard let startText = map["start"], let endText = map["end"] else { return nil }
        guard let start = parseTime(startText), let end = parseTime(endText), end >= start else { return nil }
        return SubtitleCue(
            start: start,
            end: end,
            text: normalizeText(map["text"] ?? ""),
            styleName: map["style"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// `H:MM:SS.cc` —— **厘秒**（两位小数），不是毫秒。
    /// 同样按整数毫秒算再除回秒，避免浮点噪声破坏边界断言。
    static func parseTime(_ raw: String) -> Double? {
        let groups = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard groups.count == 3 else { return nil }
        guard let hours = Double(groups[0]), let minutes = Double(groups[1]) else { return nil }
        guard hours >= 0, minutes >= 0 else { return nil }

        let secondParts = groups[2].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let seconds = Double(secondParts[0]), seconds >= 0 else { return nil }
        guard secondParts.count <= 2 else { return nil }

        var milliseconds = (hours * 3600 + minutes * 60 + seconds) * 1000
        if secondParts.count == 2 {
            let digits = secondParts[1]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let centiseconds = digits.prefix(2).padding(toLength: 2, withPad: "0", startingAt: 0)
            guard let value = Double(centiseconds) else { return nil }
            milliseconds += value * 10
        }
        return milliseconds / 1000
    }

    /// 覆盖标签 `{...}` 是给 libass 的指令，不是内容；`\N` / `\n` 是换行，`\h` 是不折行空格。
    private static func normalizeText(_ raw: String) -> String {
        var stripped = ""
        var depth = 0
        for character in raw {
            if character == "{" {
                depth += 1
                continue
            }
            if character == "}" {
                if depth > 0 { depth -= 1 }
                continue
            }
            if depth == 0 { stripped.append(character) }
        }
        return stripped
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 样式

    private static func makeStyle(_ value: String, fields: [String]) -> ASSStyle? {
        let map = fieldMap(value, fields: fields)
        guard let name = map["name"], !name.isEmpty else { return nil }
        return ASSStyle(
            name: name,
            fontName: map["fontname"] ?? "",
            fontSize: Double(map["fontsize"] ?? "") ?? 0,
            primaryColour: map["primarycolour"] ?? "",
            alignment: Int(map["alignment"] ?? "") ?? 0,
            marginLeft: Int(map["marginl"] ?? "") ?? 0,
            marginRight: Int(map["marginr"] ?? "") ?? 0,
            marginVertical: Int(map["marginv"] ?? "") ?? 0,
            isBold: flag(map["bold"]),
            isItalic: flag(map["italic"])
        )
    }

    /// ASS 用 `-1` 表示真、`0` 表示假（**负数才是开**，容易看反）。
    private static func flag(_ raw: String?) -> Bool {
        guard let raw, let value = Int(raw) else { return false }
        return value != 0
    }
}
