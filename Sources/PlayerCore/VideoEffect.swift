import Foundation

/// 帧到手之后能做什么 —— 这里只放**要在着色器里选分支**的那几种，不是滤镜商店。
///
/// 存在理由：`docs/24` 的结论是"帧能取到，但还没有下游"。下游的第一层就是
/// **同一张帧、不同的片元运算** —— 它同时也是整条管线是否真的由我们控制的判据：
/// 若渲染结果不随它变化，说明帧走的不是我们的着色器（或者根本没换过纹理）。
public enum VideoEffect: String, CaseIterable, Sendable, Equatable {
    /// 原样输出。
    case none
    /// 单色（按 BT.709 亮度）。选它做第一刀，因为它**可判**：
    /// 输出的饱和度必然为 0，而原画面不是 —— 不需要用眼睛比两张图。
    case mono

    /// 传给片元着色器的分支号。**与 MSL 里的常量必须一致**（`MPVRenderOutput` 的着色器源码）。
    public var shaderIndex: Int32 {
        switch self {
        case .none: return 0
        case .mono: return 1
        }
    }

    public var label: String {
        switch self {
        case .none: return "原样"
        case .mono: return "单色"
        }
    }

    /// 循环切下一个（调试入口只有"切一下"这一个动作）。
    public var next: VideoEffect {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}
