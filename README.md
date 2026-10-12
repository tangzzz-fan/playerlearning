# playerlearning

学习 **KSPlayer** 的设计思想，为**自建 mac / iOS 播放器**做准备。

本仓库当前处于**评估与设计阶段**，尚无播放器代码 —— 先形成对参考实现的整体认识，再动手。

## 文档索引

| 文档 | 内容 | 何时读 |
| --- | --- | --- |
| [`docs/01-KSPlayer-设计思想与整体评估.md`](docs/01-KSPlayer-设计思想与整体评估.md) | 设计思想 7 条 + 长处 9 条 + 短处 15 条 + submodule 考证 + 整体判断 | **先读这份**，建立全局认识 |
| [`docs/02-自建播放器决策记录.md`](docs/02-自建播放器决策记录.md) | 6 个决策分支的结论、理由、显式放弃项、待实测风险 | 动手前读，作为施工约束 |

## 参考源

| 项 | 值 |
| --- | --- |
| 上游仓库 | `git@github.com:kingslay/KSPlayer.git` |
| 本地 clone | `/Users/tango/Developments/KSPlayer` |
| 评估快照 | branch `main` · HEAD `01dba13`（2026-10-10） · `git describe = 2.3.4-71-g01dba13` |
| 授权 | GPL（默认）/ LGPL（付费）/ 商业另行授权 |

> 评估结论绑定上述 commit。上游 `main` 是滚动分支，若后续拉取新版本，`docs/01` 中标注为「快照事实」的数字需要重新核对。

## 下一步

按 `docs/02` 的决策落地工程骨架：SPM 双 target（`PlayerCore` / `PlayerUI`）+ XcodeGen 生成 Demo 工程。
动工前需先排掉一个风险：`kingslay/FFmpegKit` 是否提供 **iOS 真机（`ios-arm64`）** 的 libmpv slice。
