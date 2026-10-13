/// 外挂字幕开关。**`P3-T3` 只做占位**：真正的字幕加载 / 轨道选择在 `P4`。
///
/// ⚠️ 这里刻意把「**开关是开的**」和「**确实在显示字幕**」分成两个属性。
/// 理由与音频那次一样（`PlayerAudioState`）：**开关 ≠ 生效**。
/// 占位期没有字幕源，所以 `isEnabled == true` 时 `isDisplaying` 仍然是 `false` ——
/// UI 必须能如实说"字幕：开（暂无字幕源）"，而不是骗用户说已经在显示了。
///
/// 如果只留一个 `isEnabled`，`P4` 接上真字幕时会**无法区分**
/// "用户开着但文件没有字幕" 与 "用户在显示字幕"，那是又要返工的坑。
public struct PlayerSubtitleToggle: Sendable, Equatable {
    /// 用户的意图：要不要字幕。
    public private(set) var isEnabled = false
    /// 当前有没有可用的字幕源。`P4` 之前恒为 `false`（占位）。
    public private(set) var hasSource = false

    public init() {}

    public mutating func toggle() {
        isEnabled.toggle()
    }

    /// 只有"开着 **且** 有源"才算真的在显示。
    public var isDisplaying: Bool { isEnabled && hasSource }

    /// `P4` 接入真字幕时用来置位。当前无调用者（占位期）。
    public mutating func setHasSource(_ value: Bool) {
        hasSource = value
    }

    /// 界面上该显示的一行字 —— 三种状态必须**可区分**。
    public var label: String {
        if !isEnabled {
            return "字幕：关"
        }
        return hasSource ? "字幕：开" : "字幕：开（暂无字幕源）"
    }
}
