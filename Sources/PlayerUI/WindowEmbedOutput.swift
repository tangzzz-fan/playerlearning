import Foundation
import PlayerCore
import QuartzCore

private struct UncheckedPointer: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

public final class WindowEmbedOutput: CAMetalLayer, VideoOutputProtocol {
    public override init() {
        super.init()
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        configure()
    }

    public var windowEmbedHandle: Int64? {
        Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())))
    }

    public override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    public override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                let box = UncheckedPointer(raw: Unmanaged.passUnretained(self).toOpaque())
                DispatchQueue.main.sync {
                    Unmanaged<WindowEmbedOutput>.fromOpaque(box.raw).takeUnretainedValue()
                        .applyExtendedDynamicRange(newValue)
                }
            }
        }
    }

    /// 把这一层摆到宿主视图的 bounds 上，并把 `drawableSize` 同步成**像素**尺寸。
    ///
    /// 逻辑收在这里（而不是各平台各写一遍），因为"摆位置 + 防绘制尺寸退化"这件事
    /// **两个平台完全一样**，只有"从哪拿 scale"不同（`UITraitCollection` / `NSWindow`）。
    public func layout(in bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        frame = bounds
        contentsScale = scale
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // 与 `drawableSize` 的退化守卫同一口径：MoltenVK 会把 ≤1 设成 1×1 ⇒ 闪烁。
        if pixelSize.width > 1, pixelSize.height > 1 {
            drawableSize = pixelSize
        }
    }

    private func configure() {
        framebufferOnly = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    private func applyExtendedDynamicRange(_ value: Bool) {
        super.wantsExtendedDynamicRangeContent = value
    }
}
