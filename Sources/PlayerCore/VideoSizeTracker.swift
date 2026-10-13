import CoreGraphics

/// 把**分两次到达**的 `width` / `height` 合成一个尺寸，并只在合成结果**发生变化**时给出。
///
/// 为什么放在 `PlayerCore`：mpv 的 `width` / `height` 是两个独立属性、回调时机不保证成对，
/// 直接各自上报会先给出一个「半截尺寸」（如 `1920×0`）让 UI 闪一下。
/// 这段合成逻辑**没有 I/O、没有 C 依赖**，放 Core 才能被门禁覆盖
/// —— 否则它只能待在 `MPV/` 包里，而那个包跑不了单测（见 `docs/PITFALLS.md` `P-034`）。
public struct VideoSizeTracker: Sendable, Equatable {
    public private(set) var size: CGSize = .zero

    private var width = 0
    private var height = 0

    public init() {}

    /// 返回**新的合成尺寸**；无变化或两项未同时已知时返回 `nil`。
    @discardableResult
    public mutating func setWidth(_ newWidth: Int) -> CGSize? {
        width = newWidth
        return recompute()
    }

    /// 返回**新的合成尺寸**；无变化或两项未同时已知时返回 `nil`。
    @discardableResult
    public mutating func setHeight(_ newHeight: Int) -> CGSize? {
        height = newHeight
        return recompute()
    }

    private mutating func recompute() -> CGSize? {
        // 非正值一律视为「未知」。两个都未知时合成 `.zero` ——
        // 这一步是刻意的：切到纯音频（width/height 归零）时 UI 必须能感知「没有画面了」，
        // 而不是继续显示上一个视频的比例。
        let next = width > 0 && height > 0 ? CGSize(width: width, height: height) : .zero
        guard next != size else { return nil }
        size = next
        return next
    }
}
