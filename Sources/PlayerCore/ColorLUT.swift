import Foundation

/// 一张**颜色查找表**（`.cube` 的 3D LUT），以及它在这里的唯一用途：
/// 让"调色"变成一个可以插进处理器链的对象，而不是往着色器里再加一个分支。
///
/// ## 为什么是 3D LUT 而不是"再多一个 `VideoEffect`"
/// `VideoEffect` 的每一种效果都要改一次着色器源码、改一次枚举、再改一次测试常量
/// （`shaderIndex` 是**编译期**契约）。而 LUT 是**数据**：现场换一个 `.cube` 文件，
/// 不动一行代码。监看、HDR 映射、片头片尾的风格统一，靠的都是这一条。
///
/// ## 这里的 `sample` 不是"顺便给个 CPU 版"
/// 它是**定义**：`LUTFrameProcessor` 的着色器必须与这里逐点一致
/// （`testGPUMatchesTheCPUReferenceOnEverySample` 把两边的口径钉在一起）。
/// 只有一份实现写在注释里、另一份写在 MSL 里，两边的插值口径迟早会漂。
public struct ColorLUT: Sendable, Equatable {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingSize
        case oneDimensionalUnsupported
        case dimensionOutOfRange(Int)
        case malformedDimension(String)
        case malformedDomain(String)
        case domainNotIncreasing
        case valueCount(actual: Int, expected: Int)
        case malformedValue(triple: Int, text: String)
        case nonFiniteValue(triple: Int)

        public var description: String {
            switch self {
            case .missingSize:
                return "没有 LUT_3D_SIZE：这份文件不是 3D LUT"
            case .oneDimensionalUnsupported:
                return "这是 1D LUT（逐通道曲线），暂不支持 —— 当成 3D 用会把颜色整体错位"
            case .dimensionOutOfRange(let value):
                return "LUT_3D_SIZE \(value) 不可用：要求 2…\(ColorLUT.maximumDimension)"
            case .malformedDimension(let text):
                return "LUT_3D_SIZE 后面不是整数：\(text)"
            case .malformedDomain(let text):
                return "DOMAIN_MIN / DOMAIN_MAX 需要 3 个数：\(text)"
            case .domainNotIncreasing:
                return "DOMAIN_MAX 必须每一维都大于 DOMAIN_MIN"
            case .valueCount(let actual, let expected):
                return "数值个数不对：读到 \(actual) 个，按尺寸应为 \(expected) 个"
            case .malformedValue(let triple, let text):
                return "第 \(triple) 组（从 0 起）不是 3 个数：\(text)"
            case .nonFiniteValue(let triple):
                return "第 \(triple) 组里有 NaN / Inf"
            }
        }
    }

    /// 允许的最大边长。`.cube` 常见到 65；再大就该怀疑是不是写错了尺寸
    /// （129³ 的 LUT 是 12.8 MB，硬塞进 3D 纹理会直接失败）。
    public static let maximumDimension = 129

    public let dimension: Int
    /// `3 * dimension³` 个分量，**红变最快**（`.cube` 的定义，不是实现自由）。
    public let values: [Float]
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>

    /// 不合法就返回 `nil`：尺寸为 1（插值分母为 0）、份数对不上、domain 反向，都算不合法。
    ///
    /// 想拿到**说清哪里错**的行为请用 `parse(_:)` —— 这里只回答"能不能用"。
    public init?(
        dimension: Int,
        values: [Float],
        domainMin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        domainMax: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    ) {
        guard dimension >= 2, dimension <= Self.maximumDimension else { return nil }
        guard values.count == dimension * dimension * dimension * 3 else { return nil }
        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y, domainMax.z > domainMin.z else { return nil }
        self.dimension = dimension
        self.values = values
        self.domainMin = domainMin
        self.domainMax = domainMax
    }

    /// 2×2×2 恒等。三线性插值对线性函数是**精确**的，所以它等价于原样输出
    /// （`testIdentityLUTIsExact` 不留容差地钉住了这一条）。
    public static let identity = ColorLUT(
        dimension: 2,
        values: [
            0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0,
            0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1
        ]
    )!  // 上面这份常量由测试钉住，构造不出来就是改坏了常量本身。

    /// 这张表占多少字节（当成 `Float32`）。
    public var byteCount: Int { values.count * MemoryLayout<Float>.size }

    /// 反相表：`value = 1 - rgb`，边长可选。
    ///
    /// 为什么库要自带这一张：它是**"处理器真的在跑"最省事的判据**。结果是可判的
    /// （每个像素都变、且变得可预测），不需要人眼比对两张图，也不需要外部素材。
    /// 调色用的真表用户自己带 `.cube`。
    public static func inverted(dimension: Int) -> ColorLUT? {
        guard dimension >= 2, dimension <= maximumDimension else { return nil }
        var values: [Float] = []
        values.reserveCapacity(dimension * dimension * dimension * 3)
        let scale = Float(dimension - 1)
        for z in 0 ..< dimension {
            for y in 0 ..< dimension {
                for x in 0 ..< dimension {
                    values.append(contentsOf: [
                        1 - Float(x) / scale,
                        1 - Float(y) / scale,
                        1 - Float(z) / scale
                    ])
                }
            }
        }
        return ColorLUT(dimension: dimension, values: values)
    }

    // MARK: - 采样（GPU 侧的口径基准）

    /// 三线性插值取样。输入按 `domainMin…domainMax` 归一化后**夹到 [0,1]**。
    ///
    /// 为什么夹住而不是报错：HDR 素材、YUV→RGB 的溢出、以及 BT.709 之外的传输函数
    /// 都会给出负值或大于 1 的值。这些帧不该让整条链路停下来。
    ///
    /// 返回值**不再夹到 [0,1]**：LUT 本身可以写出大于 1 的值（HDR 映射就靠这个），
    /// 夹的动作发生在写进 `bgra8Unorm` 纹理那一刻（由 GPU 做）。
    public func sample(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let span = domainMax - domainMin
        let normalized = (color - domainMin) / span
        let clamped = SIMD3<Float>(
            min(max(normalized.x, 0), 1),
            min(max(normalized.y, 0), 1),
            min(max(normalized.z, 0), 1)
        )
        let scaled = clamped * Float(dimension - 1)
        let base = SIMD3<Int>(
            Int(scaled.x.rounded(.down)),
            Int(scaled.y.rounded(.down)),
            Int(scaled.z.rounded(.down))
        )
        let fraction = scaled - SIMD3<Float>(Float(base.x), Float(base.y), Float(base.z))
        // 上界夹回 `dimension - 1`：输入正好是 1.0 时 `base + 1` 会越界一个节点。
        let upper = SIMD3<Int>(
            min(base.x + 1, dimension - 1),
            min(base.y + 1, dimension - 1),
            min(base.z + 1, dimension - 1)
        )

        let c000 = node(base.x, base.y, base.z)
        let c100 = node(upper.x, base.y, base.z)
        let c010 = node(base.x, upper.y, base.z)
        let c110 = node(upper.x, upper.y, base.z)
        let c001 = node(base.x, base.y, upper.z)
        let c101 = node(upper.x, base.y, upper.z)
        let c011 = node(base.x, upper.y, upper.z)
        let c111 = node(upper.x, upper.y, upper.z)

        let bottom = mix(mix(c000, c100, fraction.x), mix(c010, c110, fraction.x), fraction.y)
        let top = mix(mix(c001, c101, fraction.x), mix(c011, c111, fraction.x), fraction.y)
        return mix(bottom, top, fraction.z)
    }

    public func sample(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        sample(SIMD3<Float>(r, g, b))
    }

    /// 第 `(x, y, z)` 个节点的颜色。**红变最快** ⇒ `(z * n + y) * n + x`。
    public func node(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
        let index = ((z * dimension + y) * dimension + x) * 3
        return SIMD3<Float>(values[index], values[index + 1], values[index + 2])
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        // 写成 `a + (b - a) * t` 而不是加权和：`a == b` 时结果**精确**等于 `a`，
        // 这条性质正是"恒等 LUT 逐像素不变"能不留容差的原因。
        a + (b - a) * t
    }

    // MARK: - 解析

    /// 解析 Adobe `.cube`（只支持 3D）。
    ///
    /// 支持：`TITLE` / `LUT_3D_SIZE` / `DOMAIN_MIN` / `DOMAIN_MAX` / `#` 注释 / 空行 / CRLF。
    /// 明确拒绝：`LUT_1D_SIZE`（另一种东西，见错误文案）。
    public static func parse(_ text: String) throws -> ColorLUT {
        var dimension: Int?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = parts.first else { continue }

            switch keyword {
            case "TITLE":
                continue

            case "LUT_1D_SIZE":
                throw ParseError.oneDimensionalUnsupported

            case "LUT_3D_SIZE":
                guard parts.count >= 2, let size = Int(parts[1]) else {
                    throw ParseError.malformedDimension(line)
                }
                guard size >= 2, size <= maximumDimension else {
                    throw ParseError.dimensionOutOfRange(size)
                }
                dimension = size

            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count >= 4,
                      let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3])
                else { throw ParseError.malformedDomain(line) }
                if keyword == "DOMAIN_MIN" {
                    domainMin = SIMD3<Float>(x, y, z)
                } else {
                    domainMax = SIMD3<Float>(x, y, z)
                }

            default:
                guard parts.count == 3,
                      let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2])
                else { throw ParseError.malformedValue(triple: values.count / 3, text: line) }
                guard r.isFinite, g.isFinite, b.isFinite else {
                    throw ParseError.nonFiniteValue(triple: values.count / 3)
                }
                values.append(contentsOf: [r, g, b])
            }
        }

        guard let dimension else { throw ParseError.missingSize }
        let expected = dimension * dimension * dimension * 3
        guard values.count == expected else {
            throw ParseError.valueCount(actual: values.count, expected: expected)
        }
        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y, domainMax.z > domainMin.z else {
            throw ParseError.domainNotIncreasing
        }
        guard let lut = ColorLUT(
            dimension: dimension, values: values, domainMin: domainMin, domainMax: domainMax
        ) else { throw ParseError.valueCount(actual: values.count, expected: expected) }
        return lut
    }
}
