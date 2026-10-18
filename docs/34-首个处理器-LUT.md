# 34 · 第一个处理器：LUT（M2 第二步）

> 一句话：**[`docs/33`](33-处理器链.md) 做完的是插线板，这一步是第一次真的插上一件电器 ——
> 而且插上之后，结果可以用数字判定（不是"看着像），慢不慢也能量出来。**

代码：`Sources/PlayerCore/ColorLUT.swift` · `Sources/PlayerProcessors/MetalPassProcessor.swift`
· `Sources/PlayerProcessors/LUTFrameProcessor.swift`
测试：`ColorLUTTests`（16 条）· `LUTFrameProcessorTests`（11 条，**真的跑 GPU 并读回像素**）

---

## 一、ELI5：为什么要专门给"第一个处理器"开一张票

`docs/33` 做的是**插线板**：三个孔、谁先谁后、插头慢了怎么顶。它能证明排插按规矩工作 ——
但证明不了**插上电饭锅真的能煮饭**。

LUT 就是那台电饭锅：第一个真的从插座取电、真的改变结果、而且**结果可以被量出来**的东西。

为什么"可量"这么关键。如果第一个处理器是"AI 上色"，跑出来画面"看着还行"，你就永远分不清三种情况：

| 看起来的样子 | 实际可能是 |
| --- | --- |
| 画面变了，挺好看 | 处理器生效了 |
| 画面变了，挺好看 | 处理器**没**生效，只是这段素材本来就这样 |
| 画面没变 | 处理器生效了，但这张图恰好没有它能改的东西 |
| 画面一顿一顿 | 处理器慢了 3 倍（也可能是解码慢，分不清） |

反相 LUT 把这三种情况一次分开：**每个像素都必须变成 `255 - 原值`**。差一个数字就是没接通，
没有"看着像"的余地。

---

## 二、三样东西，各管一段

| 文件 | 是什么 | 不负责什么 |
| --- | --- | --- |
| `ColorLUT`（PlayerCore） | **数据 + 定义**：解析 `.cube`、三线性插值、domain 归一化 | 不碰 Metal，不在渲染路径上 |
| `MetalPassProcessor`（PlayerProcessors） | **一趟全屏 pass 的外壳**：建 encoder、画四边形、管输出纹理池 | 不知道任何具体效果 |
| `LUTFrameProcessor`（PlayerProcessors） | **具体效果**：一张 3D 纹理 + 四行片元代码 | 不管调度、不管迟到策略 |

第三层薄得几乎不像个类 —— 这是故意的。深度估计、打码、放大都会共用前两层，
只写自己的片元与绑定。**如果每加一个效果都要改 `MPVRenderOutput`，这条路线就退化成定制了**
（`docs/32` §5.1 说的正是这个）。

```
MTLTexture（mpv 刚写好的帧，bgra8Unorm）
   │
   ├── MetalPassProcessor
   │     ├─ 环形池里取一张输出纹理（.private，只在 GPU 之间走）
   │     ├─ 全屏四边形（顶点由 vertex_id 直接生成，不用顶点缓冲）
   │     └─ LUT 片元：一次硬件三线性采样 → mix(原色, 查表色, strength)
   │     提交后**不等待**（等＝把"处理器慢"变成"播放卡"）
   ▼
新的 MTLTexture
   │
   └── 回到 MPVRenderOutput.draw → 上屏
```

---

## 三、三个必须写死的决定

### 3.1 队列必须与上屏是**同一个**

处理器提交完**不等待**，"结果一定在旧帧之前就绪"靠的是 Metal 的一条保证：
**同一队列内，命令缓冲按提交顺序执行**。

换一条队列，这条保证就没有了 —— 上屏那边可能在处理器还没写完时就开始采样。
表现是**偶发的一帧花屏或旧画面**，与负载相关，没有稳定的复现条件。
所以 `MPVRenderOutput` 把这一对资源直接露出来，调用方没有别的选择可做错：

```swift
public var processingDevice: MTLDevice { metalDevice }
public var processingQueue: MTLCommandQueue { queue }
```

### 3.2 提交后不等待 —— 但量测时必须等

不等待是**产品要求**（`docs/32` §5.2 的核心难点）。但它有一个副作用：
`step()` 的耗时里**不含这一趟 pass 的 GPU 时间**，于是"接上处理器还能不能实时"会被量成"几乎零开销"。

这是最容易自欺的一种读数，和"`swift build` 过就以为能用"是同一类错（`P-096`）。
所以留了一个只为量测存在的开关：

```swift
processor.waitsForCompletion = true   // 只在 -renderLUTSync 时打开
```

### 3.3 用 3D 纹理 + 硬件三线性，不自己插值

三维纹理的 `filter::linear` 就是硬件三线性，一次采样等于 CPU 侧那八次乘加。

另一条常见做法是把 N³ 铺成 N×N 的二维"贴片图"，在着色器里自己做两次 lerp ——
那段代码一旦与 CPU 侧口径不一致，画面会"只是有点偏色"，属于最难查的一类错。
既然硬件免费提供，就不要自己写一遍。

---

## 四、全篇最容易写错的一行

```metal
float3 coordinate = (base * (n - 1.0) + 0.5) / n;
```

归一化坐标 `c` 对应第 `c * n - 0.5` 个节点，而我们要的是第 `base * (n - 1)` 个节点。
反解得 `c = (base * (n - 1) + 0.5) / n`。

少了 `+ 0.5` 就整体偏半个节点 —— 表现为"暗部偏一点、亮部偏一点"，
在对称的测试图上**根本看不出来**。抓住它的是中灰：`0.5` 落在 8 个节点正中，
反相之后必须仍是 `127`（`testMidGrayStaysMidGrayUnderInterpolation`）。
变异验证 M1（去掉 `+ 0.5`）确实被这条抓住。

---

## 五、怎么用（就四行）

```swift
let lut = try ColorLUT.parse(cubeText)          // 或 ColorLUT.inverted(dimension: 33)
let processor = try LUTFrameProcessor(
    lut: lut,
    device: output.processingDevice,            // ⚠️ 必须取这两件，不要自己 new
    queue: output.processingQueue
)
output.framePipeline = FramePipeline(processors: [processor])

// seek / 换片之后 —— 不调就会让跳转后的第一帧被旧结果顶替（docs/33 §五）
output.resetFramePipeline()
```

`strength` 是可变的（0 = 原样，1 = 全量）：拖动滑块**不要重建处理器**，
重建会让 `setProcessors` 清掉上一次结果，画面闪一下。

---

## 六、真机怎么量（这是唯一还没有答案的问题）

本机单测能证明"处理得对"，证明不了"插上之后还能实时"。后者只能真机量：

```bash
# 1) 装到真机（Release 构建才代表实际帧率；Debug 的 Swift 开销会污染读数）
xcodebuild -project Demo/PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
  -destination 'id=<真机 UDID，用 xcrun devicectl list devices 现查>' \
  -configuration Release -derivedDataPath Demo/DD-Device \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS=-disable-sandbox build

# 2) 起本机服务器（真机不能走 127.0.0.1）
MACIP=$(ipconfig getifaddr en1 || ipconfig getifaddr en0)
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2 --host 0.0.0.0

# 3) 压帧：先不带处理器，再看带处理器 —— 两次的差才是处理器的代价
xcrun devicectl device process launch --device <真机 UDID> --console --terminate-existing \
  com.playerstack.app -- \
  -renderBench http://$MACIP:8765/<4K 素材>.mp4 -renderTarget native -renderBenchFrames 120

xcrun devicectl device process launch --device <真机 UDID> --console --terminate-existing \
  com.playerstack.app -- \
  -renderBench http://$MACIP:8765/<4K 素材>.mp4 -renderTarget native -renderBenchFrames 120 \
  -renderLUT invert -renderLUTSize 33 -renderLUTSync
```

判据（三条都要看，缺一条读不出结论）：

| 输出 | 说明什么 |
| --- | --- |
| `[lut] 已接上 name=invert size=33 sync=true` | 表造出来了、管线建起来了 |
| `[bench] pipeline=applied=[lut] lag=0` | **这一帧真的被加工了**（`applied` 空 = 接上等于没接） |
| 两次 `[bench] 整帧` 的 p50 之差 | 处理器的真实代价（4K 33³ 的预算参照：`docs/25` 按源码 `44.34 ms` / 按上屏 `11.51 ms`） |

⚠️ **必须 `-renderLUTSync`**。不加的话 `timings` 里不含那一趟 pass，会得到"处理器 0 ms"的假读数。

---

## 七、已验证 / 未验证

**已验证**（本机当场跑，数字可复量）

| 项 | 结果 |
| --- | --- |
| `ColorLUTTests` | 16 条全绿（解析 / 顺序 / domain / 夹取 / 插值 / 公开 `init` 的守卫） |
| `LUTFrameProcessorTests` | 11 条全绿 —— **真的 `swift test` 里跑 Metal**（本机 M2），读回像素与 CPU 逐点对账 |
| 变异验证 | 5 个变异体 **5/5 全部被抓住**（少 `+0.5` / 忽略 strength / 节点顺序写成蓝最快 / 尺寸 1 放行 / 换尺寸不重建池） |
| 一次漏网 | 第一轮 4/5，"尺寸 1 放行"没抓住 ⇒ `P-098`（守卫写在两处，只测到一处） |
| 全量套件 | 98 + 11 + 0 + 321 = **430 条全绿**（原 402，+28） |
| iOS 构建 | `xcodebuild -destination 'generic/platform=iOS'` → `BUILD SUCCEEDED`（此前被 `P-099` 拦住一次） |

**未验证**（别当成结论）

- **真机 4K + 处理器的帧率**：一个数字都没有。`waitsForCompletion` 那条命令还没跑过。
- **跨队列竞争**：只写了"必须同一队列"，**没有**做过故意用两条队列的对照实验
  （这种 bug 本来就没有稳定复现条件，只能靠约定）。
- **环形池深度 3 是否够**：与 `MPVRenderOutput` 的 `CVPixelBuffer` 池取同一个数，
  但那是**别处的经验**，不是量出来的。
- **`-renderLUT` 入口只在 iOS 上编过**：Demo 的 macOS target 没有接 `PlayerProcessors`。

---

## 八、与既有文档的关系

| 文档 | 关系 |
| --- | --- |
| [`docs/33`](33-处理器链.md) | 上一层（协议 + 迟到策略）。本文是它的第一个真实使用者 |
| [`docs/32`](32-帧管道路线.md) §六 | M2 列了三个参考实现（字幕 / LUT / 深度），本文交付第二个 |
| [`docs/25`](25-RenderAPI上屏与吞吐.md) | 44.34 / 11.51 的出处；接上处理器后要按 §六 重测 |
| [`P-099`](PITFALLS.md) | `.managed` 在 iOS 上编译期不存在 —— 只跑 `swift build` 等于没验 iOS |

**下一步（按价值排）**

1. **真机量一次**（§六）—— 这是 M2 唯一还没有数字的判据。
2. 把 `-renderLUT` 接到 `-renderDisplay` 的常驻日志里，看**连续 10 分钟**的 `lag` 分布，
   用它定 `maxAgeFrames` 的合理值（现在默认 2 是猜的）。
3. 深处理器（异步 + `.holdLastResult`）：那才是 2D→3D 的真正入口，也是
   `StaleFramePolicy` 第一次被真实使用的地方。
