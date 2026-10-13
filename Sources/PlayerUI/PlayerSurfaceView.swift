import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 把 `WindowEmbedOutput`（本质是一个 `CAMetalLayer`）挂进 SwiftUI。
///
/// ⚠️ 顺序是硬约束：**先有 surface，才有句柄，才能建内核** ——
/// `wid` 必须在 `mpv_initialize` **之前**给定，否则内核静默走 `vo=null`（`docs/09` 缺陷 a）。
public struct PlayerSurfaceView: View {
    private let output: WindowEmbedOutput

    public init(output: WindowEmbedOutput) {
        self.output = output
    }

    public var body: some View {
        #if canImport(UIKit)
        UIKitSurface(output: output)
        #elseif canImport(AppKit)
        AppKitSurface(output: output)
        #endif
    }
}

#if canImport(UIKit)

private struct UIKitSurface: UIViewRepresentable {
    let output: WindowEmbedOutput

    func makeUIView(context: Context) -> UIView {
        LayerHostView(output: output)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.setNeedsLayout()
    }
}

private final class LayerHostView: UIView {
    private let output: WindowEmbedOutput

    init(output: WindowEmbedOutput) {
        self.output = output
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(output)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 关掉隐式动画：尺寸变更时不要看到 layer 动画（会与视频帧打架）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        output.layout(in: bounds, scale: traitCollection.displayScale)
    }
}

#elseif canImport(AppKit)

private struct AppKitSurface: NSViewRepresentable {
    let output: WindowEmbedOutput

    func makeNSView(context: Context) -> NSView {
        AppKitLayerHostView(output: output)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.needsLayout = true
    }
}

private final class AppKitLayerHostView: NSView {
    private let output: WindowEmbedOutput

    init(output: WindowEmbedOutput) {
        self.output = output
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(output)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        output.layout(in: bounds, scale: window?.backingScaleFactor ?? 1)
    }
}

#endif
