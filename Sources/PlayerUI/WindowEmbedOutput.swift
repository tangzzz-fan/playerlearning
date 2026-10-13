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

    private func configure() {
        framebufferOnly = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    private func applyExtendedDynamicRange(_ value: Bool) {
        super.wantsExtendedDynamicRangeContent = value
    }
}
