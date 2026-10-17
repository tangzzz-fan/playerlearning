import CoreGraphics
import Foundation

/// 画面在容器里的**摆放方式**。
///
/// 注意 `.fit` 与 `.fill` 的取值刻意与 `AVLayerVideoGravity` / SwiftUI 的
/// `contentMode` 一致（含/填），别按"哪个词听着更宽松"来理解。
public enum VideoFit: Sendable, Equatable {
    /// 整幅画面都在容器内（可能留黑边）。
    case fit
    /// 铺满容器（可能裁掉画面边缘）。
    case fill
    /// 拉伸到容器（**不保比例**；只有明确要变形时才用）。
    case stretch
}

/// 帧 → 图层的**摆放几何**：纯函数，因此可单测、可变异覆盖。
///
/// 为什么单独抽出来：这件事在两处被用到 ——
/// ① Metal 顶点（决定 quad 在 NDC 里的位置）；
/// ② 测试与调试（"画面应该占哪一块"）。
/// 两边各写一遍必然漂移，而漂移的表现是"画面比例看着不对"这种**没法自动发现**的问题。
public enum VideoFitRect {
    /// 把 `content`（内容尺寸）摆进 `container`（容器尺寸），返回应占的矩形。
    ///
    /// 两个退化守卫，方向相反、都必要：
    /// - **容器**无效（0 / 负 / NaN）⇒ 返回 `.zero`：没有地方可放。
    /// - **内容**无效（0 / 负 / NaN）⇒ 返回**整个容器**：此时"铺满"是唯一不会骗人的选择，
    ///   按 0 处理会算出一个零尺寸矩形，画面直接消失（`docs/09` 缺陷 a 那一族：
    ///   尺寸退化被静默接受）。
    public static func rect(content: CGSize, in container: CGSize, fit: VideoFit) -> CGRect {
        guard container.width.isFinite, container.height.isFinite,
              container.width > 0, container.height > 0
        else { return .zero }

        let full = CGRect(origin: .zero, size: container)
        guard content.width.isFinite, content.height.isFinite,
              content.width > 0, content.height > 0
        else { return full }

        switch fit {
        case .stretch:
            return full
        case .fit:
            let scale = min(container.width / content.width, container.height / content.height)
            return centered(size: CGSize(width: content.width * scale, height: content.height * scale), in: container)
        case .fill:
            let scale = max(container.width / content.width, container.height / content.height)
            return centered(size: CGSize(width: content.width * scale, height: content.height * scale), in: container)
        }
    }

    /// 把 `content` **等比缩到** `container` 能装下，且**不放大**（上限 1.0）。
    ///
    /// 用途：软件后端按**这块尺寸**渲染而不是按源码尺寸 ——
    /// 软件后端的成本跟**目标像素数**成正比，而与源分辨率无关（实测数据见 `docs/25` §三）。
    /// 不放大是因为放大发生在 Metal 那一步（GPU 免费且质量更好），
    /// 在 CPU 上先放大一遍纯属浪费。
    public static func scaledSize(content: CGSize, in container: CGSize) -> CGSize {
        guard content.width.isFinite, content.height.isFinite,
              content.width > 0, content.height > 0,
              container.width.isFinite, container.height.isFinite,
              container.width > 0, container.height > 0
        else { return content }
        let scale = min(1, min(container.width / content.width, container.height / content.height))
        guard scale < 1 else { return content }
        return CGSize(
            width: max(1, (content.width * scale).rounded()),
            height: max(1, (content.height * scale).rounded())
        )
    }

    private static func centered(size: CGSize, in container: CGSize) -> CGRect {
        CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
