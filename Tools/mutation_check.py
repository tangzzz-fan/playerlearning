#!/usr/bin/env python3
import pathlib
import shutil
import signal
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKUP = ROOT / ".mutation-backup"
TEST_TIMEOUT = 180

MUTATIONS = [
    ("Sources/PlayerCore/PlayerKernelRegistry.swift",
     "kernelTypes.count > 1 ? kernelTypes[1] : nil",
     "kernelTypes.count > 0 ? kernelTypes[1] : nil",
     "registry: 越界守卫 count > 1 放宽为 > 0"),
    ("Sources/PlayerCore/PlayerKernelRegistry.swift",
     "kernelTypes.count > 1 ? kernelTypes[1] : nil",
     "kernelTypes.count > 2 ? kernelTypes[1] : nil",
     "registry: 越界守卫 count > 1 收紧为 > 2"),
    ("Sources/PlayerCore/PlayerKernelRegistry.swift",
     "kernelTypes.first",
     "kernelTypes.last",
     "registry: firstKernelType 取 last"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "currentTime = seconds",
     "currentTime = seconds + 1",
     "fake: currentTime 偏移 +1"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "emit(.durationChanged(scriptedDuration))",
     "emit(.durationChanged(scriptedDuration + 1))",
     "fake: load 上报时长 +1"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "playCallCount += 1",
     "playCallCount += 2",
     "fake: playCallCount 步进 +2"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "emit(.stateChanged(.idle))",
     "emit(.stateChanged(.paused))",
     "fake: stop 误报 .paused"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "emit(.stateChanged(.readyToPlay))",
     "",
     "fake: load 不再上报 .readyToPlay"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "seekRequests.append(seconds)",
     "seekRequests.append(seconds + 1)",
     "fake: seek 记录偏移 +1"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "outcome(for: newState) == .applied",
     "outcome(for: newState) != .applied",
     "machine: canTransition 判定取反"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "        if newState == state {\n            return .unchanged\n        }",
     "        if newState != state {\n            return .unchanged\n        }",
     "machine: 同态判定取反"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "        return Self.isLegal(from: state, to: newState) ? .applied : .rejected",
     "        return .applied",
     "machine: 一律放行为 .applied"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "        let outcome = outcome(for: newState)\n        if outcome == .applied {\n            state = newState\n        }\n        return outcome",
     "        return outcome(for: newState)",
     "machine: 不再写入新状态"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "        case (.readyToPlay, .playing), (.readyToPlay, .preparing), (.readyToPlay, .idle):",
     "        case (.readyToPlay, .playing), (.readyToPlay, .preparing), (.readyToPlay, .idle),\n             (.readyToPlay, .paused):",
     "machine: 误把 readyToPlay → paused 当合法"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "        case (.finished, .preparing), (.finished, .idle):",
     "        case (.finished, .idle):",
     "machine: 删掉 finished → preparing（重播）"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "        default:\n            false",
     "        default:\n            true",
     "machine: 默认放行一切迁移"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "abs(currentTime - lastPublishedTime) < interval",
     "abs(currentTime - lastPublishedTime) <= interval",
     "time: 节流边界 < 放宽为 <="),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "Swift.min(Swift.max(seconds, intervalRange.lowerBound), intervalRange.upperBound)",
     "Swift.min(Swift.max(seconds, 0.1), intervalRange.upperBound)",
     "time: 间隔下限 0.2 悄悄放宽为 0.1"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "seconds.isFinite && seconds > 0 ? seconds : 0",
     "seconds.isFinite ? seconds : 0",
     "time: 不再拦截负时长"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "guard !seconds.isNaN else { return 0 }",
     "guard !seconds.isNaN else { return currentTime }",
     "time: NaN 目标回退到当前时间而非 0"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "Swift.min(lowerBounded, duration)",
     "Swift.max(lowerBounded, duration)",
     "time: 钳制上界用 max 而非 min"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "guard duration > 0 else {",
     "guard duration >= 0 else {",
     "time: 未知时长的判定 > 0 放宽为 >= 0"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "        lastPublishedTime = currentTime\n        return PlayerTimeUpdate(currentTime: currentTime, duration: duration)",
     "        return PlayerTimeUpdate(currentTime: currentTime, duration: duration)",
     "time: 发布后不更新节流基线"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "return PlayerTimeUpdate(currentTime: currentTime, duration: duration)",
     "return PlayerTimeUpdate(currentTime: currentTime, duration: 0)",
     "time: 发布时丢掉时长"),
    ("Sources/PlayerCore/PlayerTimeModel.swift",
     "                var model = self",
     "                var model = PlayerTimeModel()",
     "time: 时间流不继承模型配置"),
    ("Sources/PlayerUI/WindowEmbedOutput.swift",
     "if Int(newValue.width) > 1 && Int(newValue.height) > 1 {",
     "if Int(newValue.width) > 1 || Int(newValue.height) > 1 {",
     "surface: drawableSize 退化守卫把 && 写成 ||"),
    ("Sources/PlayerUI/WindowEmbedOutput.swift",
     "if Int(newValue.width) > 1 && Int(newValue.height) > 1 {",
     "if Int(newValue.width) >= 1 && Int(newValue.height) >= 1 {",
     "surface: drawableSize 退化守卫放宽为 >= 1"),
]


def restore() -> None:
    if not BACKUP.is_dir():
        return
    for copy in BACKUP.rglob("*"):
        if not copy.is_file():
            continue
        target = ROOT / copy.relative_to(BACKUP)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(copy, target)
    shutil.rmtree(BACKUP, ignore_errors=True)


def guard(_signum, _frame) -> None:
    print("\n收到中断信号，正在还原源文件…", flush=True)
    restore()
    sys.exit(130)


def snapshot() -> None:
    BACKUP.mkdir(exist_ok=True)
    for relative in {relative for relative, *_ in MUTATIONS}:
        target = BACKUP / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)


def run_suite() -> str:
    try:
        result = subprocess.run(
            ["swift", "test"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=TEST_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return "timeout"
    output = result.stdout + result.stderr
    if result.returncode == 0 and "error:" not in output:
        return "green"
    return "red"


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--restore":
        restore()
        print("已从备份还原")
        return 0

    if BACKUP.is_dir():
        print("发现上次运行残留的备份，先还原", flush=True)
        restore()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, guard)

    snapshot()
    try:
        if run_suite() != "green":
            print("基线异常：变异前套件就不是绿的，终止", flush=True)
            return 1

        killed: list[str] = []
        survived: list[str] = []
        timed_out: list[str] = []

        for relative, old, new, label in MUTATIONS:
            path = ROOT / relative
            text = path.read_text()
            if text.count(old) != 1:
                print(f"  跳过（匹配数 {text.count(old)} ≠ 1）  {label}", flush=True)
                survived.append(label)
                continue
            path.write_text(text.replace(old, new))
            verdict = run_suite()
            shutil.copyfile(BACKUP / relative, path)
            if verdict == "red":
                print(f"  KILLED    {label}", flush=True)
                killed.append(label)
            elif verdict == "green":
                print(f"  SURVIVED  {label}", flush=True)
                survived.append(label)
            else:
                print(f"  TIMEOUT   {label}", flush=True)
                timed_out.append(label)
    finally:
        restore()

    print(flush=True)
    print(
        f"变异体 {len(MUTATIONS)} · 杀死 {len(killed)} · 存活 {len(survived)} · 超时 {len(timed_out)}",
        flush=True,
    )
    if survived:
        print("存活清单：", flush=True)
        for label in survived:
            print(f"  - {label}", flush=True)
    if timed_out:
        print("超时清单（套件疑似会挂死，属测试设计问题）：", flush=True)
        for label in timed_out:
            print(f"  - {label}", flush=True)
    return 1 if survived or timed_out else 0


if __name__ == "__main__":
    sys.exit(main())
