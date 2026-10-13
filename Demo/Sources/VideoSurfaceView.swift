import PlayerUI
import SwiftUI

/// 把 `WindowEmbedOutput`（本质是一个 `CAMetalLayer`）挂进 SwiftUI。
///
/// ⚠️ 顺序是硬约束：**先有 surface，才有句柄，才能建内核** ——
/// `wid` 必须在 `mpv_initialize` **之前**给定，否则内核静默走 `vo=null`（`docs/09` 缺陷 a，已在 `P2-T7` 收口）。
struct VideoSurfaceView: UIViewRepresentable {
    let output: WindowEmbedOutput

    func makeUIView(context: Context) -> UIView {
        LayerHostView(output: output)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.setNeedsLayout()
    }
}

/// 只负责把 `output` 这一层摆到自己的 bounds 上，并把 `drawableSize` 同步成像素尺寸。
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

        output.frame = bounds
        output.contentsScale = traitCollection.displayScale
        let pixelSize = CGSize(
            width: bounds.width * traitCollection.displayScale,
            height: bounds.height * traitCollection.displayScale
        )
        // 与 `WindowEmbedOutput.drawableSize` 的退化守卫同一口径：MoltenVK 会把 ≤1 设成 1×1。
        if pixelSize.width > 1, pixelSize.height > 1 {
            output.drawableSize = pixelSize
        }
    }
}
