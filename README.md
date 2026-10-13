# playerlearning

学习 **KSPlayer** 的设计思想，为**自建 mac / iOS 播放器**做准备。

当前处于**评估与设计阶段**，尚无播放器代码 —— 先形成对参考实现的整体认识，再动手。

## 文档索引

| 文档 | 内容 | 何时读 |
| --- | --- | --- |
| [`docs/01-KSPlayer-设计思想与整体评估.md`](docs/01-KSPlayer-设计思想与整体评估.md) | 设计思想 8 条 + 长处 9 条 + 短处 15 条 + submodule 考证 + 整体判断 | **先读这份**，建立全局认识 |
| [`docs/02-自建播放器决策记录.md`](docs/02-自建播放器决策记录.md) | 11 条决策、逐条理由与被否方案、显式放弃清单、待验证风险、施工硬约束 | 动手前读，作为施工约束 |
| [`docs/03-路线图.md`](docs/03-路线图.md) | Phase 0–7 拆解、判定门 G0–G7、横切事项、里程碑定义、未定项与决策回访点 | **开工时读**，按 ticket 推进 |

## 目录结构

```
playerlearning/
├── docs/                  ← 我们的分析与决策（本仓库自己的产出）
│   ├── 01-KSPlayer-设计思想与整体评估.md
│   ├── 02-自建播放器决策记录.md
│   └── 03-路线图.md
└── vendor/
    └── ksplayer/          ← KSPlayer 的只读学习副本（GPL，非我们的代码）
        ├── NOTICE.md      ← 来源 / 版本 / 许可 / 剔除说明 / 不可构建声明（先读）
        ├── Sources/       ← KSPlayerUI + MPVPlayer（13,920 行）
        ├── Documents/     ← 原理详解 + AVPlayer踩坑记
        └── ...
```

## 参考源

| 项 | 值 |
| --- | --- |
| 上游仓库 | `git@github.com:kingslay/KSPlayer.git` |
| 评估快照 | branch `main` · HEAD `01dba13`（2026-10-10） · `git describe = 2.3.4-71-g01dba13` |
| 授权 | GPL（默认）/ LGPL（付费）/ 商业另行授权 |

> 评估结论绑定上述 commit。上游 `main` 是滚动分支，若后续拉取新版本，`docs/01` 中标注为「快照事实」的数字需要重新核对。

## ⚠️ 许可提示

`vendor/ksplayer/` 是 GPL 代码。把它放进本仓库意味着**本仓库的 `vendor/` 部分受 GPL 约束**。

- 当前（自用、不对外分发）：无实际影响。
- 若将来要分发本仓库：需重新评估（移除 `vendor/`，或整体遵守 GPL）。
- 本副本**不是**我们的代码，任何对外产物都不应链接或引用它。

详见 [`vendor/ksplayer/NOTICE.md`](vendor/ksplayer/NOTICE.md)。

## 下一步

按 `docs/03` 从 **Phase 0 · 风险排除** 开始，一期只做一件事：

1. `P0-T1` 实测 `kingslay/FFmpegKit` 是否提供 **iOS 真机（`ios-arm64`）** 的 libmpv slice —— 这是唯一可能推翻整体设计的阻塞项。
2. `P0-T2` 最小冒烟：iOS 模拟器上 `wid` 嵌入播一个本地 mp4。

> **在 G0 通过之前，不写任何要长期留存的播放器代码。**
