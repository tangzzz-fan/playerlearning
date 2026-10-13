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
    ("Sources/PlayerCore/PlayerController.swift",
     "guard machine.transition(to: newState) == .applied else { return }",
     "guard machine.transition(to: newState) != .rejected else { return }",
     "controller: 同态状态也上报"),
    ("Sources/PlayerCore/PlayerController.swift",
     "guard machine.transition(to: newState) == .applied else { return }",
     "guard machine.transition(to: newState) == .rejected else { return }",
     "controller: 状态上报条件取反为 .rejected"),
    ("Sources/PlayerCore/PlayerController.swift",
     "continuation?.yield(.stateChanged(newState))",
     "continuation?.yield(.stateChanged(.idle))",
     "controller: 状态上报恒为 .idle"),
    ("Sources/PlayerCore/PlayerController.swift",
     "case .currentTimeChanged, .durationChanged:",
     "case .currentTimeChanged:",
     "controller: 丢弃时长事件"),
    ("Sources/PlayerCore/PlayerController.swift",
     "continuation?.yield(.timeChanged(update))",
     "continuation?.yield(.timeChanged(PlayerTimeUpdate(currentTime: update.currentTime, duration: 0)))",
     "controller: 时间上报丢时长"),
    ("Sources/PlayerCore/PlayerController.swift",
     "guard flag != isBuffering else { return }",
     "guard flag == isBuffering else { return }",
     "controller: 缓冲翻转判定取反"),
    ("Sources/PlayerCore/PlayerController.swift",
     "isBuffering = flag",
     "isBuffering = !flag",
     "controller: 缓冲态写入取反"),
    ("Sources/PlayerCore/PlayerController.swift",
     "await kernel.seek(to: time.clampSeekTarget(seconds))",
     "await kernel.seek(to: seconds)",
     "controller: seek 未钳制"),
    ("Sources/PlayerCore/PlayerController.swift",
     "time = PlayerTimeModel(interval: timeInterval)",
     "time = PlayerTimeModel()",
     "controller: 时间模型不继承间隔配置"),
    ("Sources/PlayerCore/PlayerController.swift",
     "state: machine.state,",
     "state: .idle,",
     "controller: 快照状态恒为 .idle"),
    ("Sources/PlayerCore/PlayerController.swift",
     "duration: time.duration,",
     "duration: 0,",
     "controller: 快照丢时长"),
    ("Sources/PlayerCore/PlayerController.swift",
     "isBuffering: isBuffering",
     "isBuffering: false",
     "controller: 快照丢缓冲态"),
    ("Sources/PlayerCore/PlayerController.swift",
     "guard size != naturalSize else { return }",
     "guard size == naturalSize else { return }",
     "controller: 视频尺寸翻转判定取反"),
    ("Sources/PlayerCore/PlayerController.swift",
     "naturalSize = size",
     "naturalSize = CGSize(width: size.height, height: size.width)",
     "controller: 视频尺寸写入时宽高互换"),
    ("Sources/PlayerCore/PlayerController.swift",
     "continuation?.yield(.videoSizeChanged(size))",
     "continuation?.yield(.videoSizeChanged(.zero))",
     "controller: 视频尺寸上报恒为 .zero"),
    ("Sources/PlayerCore/PlayerController.swift",
     "naturalSize: naturalSize",
     "naturalSize: .zero",
     "controller: 快照丢视频尺寸"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "if scriptedNaturalSize != .zero {",
     "if scriptedNaturalSize == .zero {",
     "fake: 尺寸上报条件取反"),
    ("Sources/PlayerCore/FakeKernel.swift",
     "naturalSize = size",
     "naturalSize = CGSize(width: size.height, height: size.width)",
     "fake: 视频尺寸写入时宽高互换"),
    ("Sources/PlayerCore/VideoSizeTracker.swift",
     "let next = width > 0 && height > 0 ? CGSize(width: width, height: height) : .zero",
     "let next = width > 0 || height > 0 ? CGSize(width: width, height: height) : .zero",
     "sizeTracker: 两项已知的 && 放宽成 ||（半截尺寸也上报）"),
    ("Sources/PlayerCore/VideoSizeTracker.swift",
     "let next = width > 0 && height > 0 ? CGSize(width: width, height: height) : .zero",
     "let next = width >= 0 && height >= 0 ? CGSize(width: width, height: height) : .zero",
     "sizeTracker: 正值判定 > 0 放宽为 >= 0（0 被当有效尺寸）"),
    ("Sources/PlayerCore/VideoSizeTracker.swift",
     "guard next != size else { return nil }",
     "guard next == size else { return nil }",
     "sizeTracker: 变化判定取反（永不改变时反而上报）"),
    ("Sources/PlayerCore/VideoSizeTracker.swift",
     "        size = next\n        return next",
     "        size = .zero\n        return next",
     "sizeTracker: 上报后不更新缓存（同尺寸会重复上报）"),
    ("Sources/PlayerCore/VideoSizeTracker.swift",
     "let next = width > 0 && height > 0 ? CGSize(width: width, height: height) : .zero",
     "let next = width > 0 && height > 0 ? CGSize(width: height, height: width) : .zero",
     "sizeTracker: 合成尺寸宽高互换"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "if newState == .failed {\n            return true\n        }",
     "if false {\n            return true\n        }",
     "machine: 取消「失败永远可达」（回到按源态白名单）"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "if newState == .failed {\n            return true\n        }",
     "if newState != .failed {\n            return true\n        }",
     "machine: 无条件放行一切迁移（只剩 .failed 要审批）"),
    ("Sources/PlayerCore/PlayerStateMachine.swift",
     "if newState == .failed {",
     "if newState == .idle {",
     "machine: 把「永远可达」错挂到 .idle 上"),
    ("Sources/PlayerCore/PlaybackEndReason.swift",
     "case .endOfStream:\n            .finished",
     "case .endOfStream:\n            .failed",
     "endReason: EOF 被当成失败"),
    ("Sources/PlayerCore/PlaybackEndReason.swift",
     "case .error:\n            .failed",
     "case .error:\n            .finished",
     "endReason: 错误被当成正常播完"),
    ("Sources/PlayerCore/PlaybackEndReason.swift",
     "case .error:\n            .failed",
     "case .error:\n            nil",
     "endReason: 错误不上报（静默）"),
    ("Sources/PlayerCore/PlaybackEndReason.swift",
     "case .stopped:\n            .idle",
     "case .stopped:\n            .finished",
     "endReason: 主动停止被当成播完"),
    ("Sources/PlayerCore/PlaybackEndReason.swift",
     "case .quit, .redirect:\n            nil",
     "case .quit, .redirect:\n            .idle",
     "endReason: 退出/重定向被误报为 idle"),
    ("Sources/PlayerCore/PlayerAudioState.swift",
     "public var isDecoding: Bool { decoderSampleRate > 0 }",
     "public var isDecoding: Bool { decoderSampleRate >= 0 }",
     "audio: isDecoding 的 > 0 放宽为 >= 0（无音轨也报在解码）"),
    ("Sources/PlayerCore/PlayerAudioState.swift",
     "public var isOutputting: Bool { outputSampleRate > 0 }",
     "public var isOutputting: Bool { decoderSampleRate > 0 }",
     "audio: 出声判定错用解码端采样率（解码当成出声）"),
    ("Sources/PlayerCore/PlayerAudioState.swift",
     "        guard rate != decoderSampleRate else { return nil }",
     "        guard rate == decoderSampleRate else { return nil }",
     "audio: 解码端变化判定取反"),
    ("Sources/PlayerCore/PlayerAudioState.swift",
     "        guard rate != outputSampleRate else { return nil }",
     "        guard rate == outputSampleRate else { return nil }",
     "audio: 输出端变化判定取反"),
    ("Sources/PlayerCore/PlayerController.swift",
     "        case .audioChanged(let state):\n            guard state != audio else { return }\n            audio = state\n            continuation?.yield(.audioChanged(state))",
     "        case .audioChanged(let state):\n            guard state != audio else { return }\n            audio = state",
     "controller: 音频状态不上报"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        guard duration > 0, currentTime.isFinite else { return 0 }",
     "        guard duration > 0 else { return 0 }",
     "viewModel: progress 不再拦非有限值（NaN 会漏进进度条）"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        return min(max(currentTime / duration, 0), 1)",
     "        return currentTime / duration",
     "viewModel: progress 不钳制到 0…1"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        guard naturalSize.width > 0, naturalSize.height > 0 else { return 16.0 / 9.0 }",
     "        guard naturalSize.width > 0, naturalSize.height > 0 else { return 9.0 / 16.0 }",
     "viewModel: 尺寸未知时的兜底比例写反"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        return naturalSize.width / naturalSize.height",
     "        return naturalSize.height / naturalSize.width",
     "viewModel: 宽高比取反（竖屏素材会躺下）"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "    public var isPlaying: Bool { state == .playing }",
     "    public var isPlaying: Bool { state != .playing }",
     "viewModel: isPlaying 判定取反"),
    ("Sources/PlayerUI/PlayerControlBar.swift",
     "        guard seconds.isFinite, seconds > 0 else { return \"0:00\" }",
     "        guard seconds > 0 else { return \"0:00\" }",
     "clock: 不再拦非有限值（NaN 直接崩在 Int(_:)）"),
    ("Sources/PlayerUI/PlayerControlBar.swift",
     "        let total = Int(seconds.rounded(.down))",
     "        let total = Int(seconds.rounded())",
     "clock: 取整改为四舍五入（59.9 提前跳 1:00）"),
    ("Sources/PlayerUI/PlayerControlBar.swift",
     "        if hours > 0 {",
     "        if hours >= 0 {",
     "clock: 时长判定放宽为 >= 0（永远显示 h:mm:ss）"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        wasPlayingBeforeScrub = isPlaying",
     "        wasPlayingBeforeScrub = !isPlaying",
     "scrub: 记录「本来在播」取反（松手后该播的不播）"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        previewTime = currentTime.isFinite ? max(0, currentTime) : 0",
     "        previewTime = currentTime",
     "scrub: begin 不拦负值/非有限值"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        guard isScrubbing else { return }\n        let clamped",
     "        guard !isScrubbing else { return }\n        let clamped",
     "scrub: update 的「必须先按下」判定取反"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0",
     "        let clamped = min(max(fraction, 0), 1)",
     "scrub: 不拦非有限比例（NaN 会漏进预览时间）"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0",
     "        let clamped = fraction.isFinite ? fraction : 0",
     "scrub: 比例不钳到 0…1（能拖到时长之外）"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        previewTime = duration > 0 ? clamped * duration : 0",
     "        previewTime = duration > 0 ? clamped * duration : clamped",
     "scrub: 时长未知时把比例当秒用"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        guard isScrubbing else { return nil }\n        isScrubbing = false",
     "        guard isScrubbing == false else { return nil }\n        isScrubbing = false",
     "scrub: 没按下也能松手（点一下就跳）"),
    ("Sources/PlayerUI/PlayerScrubModel.swift",
     "        isScrubbing = false\n        wasPlayingBeforeScrub = false\n        return previewTime",
     "        isScrubbing = false\n        wasPlayingBeforeScrub = false\n        return previewTime * 2",
     "scrub: 松手落点翻倍"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        if scrub.wasPlayingBeforeScrub {\n            await controller.pause()\n        }",
     "",
     "viewModel: 拖拽期间不暂停（声音在手指底下继续走）"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        guard scrub.isScrubbing else { return progress }",
     "        guard true else { return progress }",
     "viewModel: displayProgress 不显示拖拽预览"),
    ("Sources/PlayerUI/PlayerFullscreenModel.swift",
     "        mode = mode == .inline ? .fullscreen : .inline",
     "        mode = mode == .inline ? .inline : .fullscreen",
     "fullscreen: 切换取反（点全屏反而不全屏）"),
    ("Sources/PlayerUI/PlayerFullscreenModel.swift",
     "    public var hidesHostChrome: Bool { mode == .fullscreen }",
     "    public var hidesHostChrome: Bool { mode != .fullscreen }",
     "fullscreen: 宿主外壳让位判定取反"),
    ("Sources/PlayerUI/PlayerFullscreenModel.swift",
     "    public mutating func reset() {\n        mode = .inline\n    }",
     "    public mutating func reset() {\n        mode = .fullscreen\n    }",
     "fullscreen: 复位反而进全屏（下次进来一开屏就是全屏）"),
    ("Sources/PlayerUI/PlayerSubtitleToggle.swift",
     "        isEnabled.toggle()",
     "        isEnabled = false",
     "subtitle: 开关只会关不会开"),
    ("Sources/PlayerUI/PlayerSubtitleToggle.swift",
     "    public var isDisplaying: Bool { isEnabled && hasSource }",
     "    public var isDisplaying: Bool { isEnabled }",
     "subtitle: 「开关≠生效」丢失（没源也说在显示）"),
    ("Sources/PlayerUI/PlayerSubtitleToggle.swift",
     "    public var isDisplaying: Bool { isEnabled && hasSource }",
     "    public var isDisplaying: Bool { hasSource }",
     "subtitle: 只看有没有源，不管开关"),
    ("Sources/PlayerUI/PlayerSubtitleToggle.swift",
     "        if !isEnabled {\n            return \"字幕：关\"\n        }",
     "        if isEnabled {\n            return \"字幕：关\"\n        }",
     "subtitle: 标签的开关判定取反"),
    ("Sources/PlayerUI/PlayerSubtitleToggle.swift",
     "        return hasSource ? \"字幕：开\" : \"字幕：开（暂无字幕源）\"",
     "        return \"字幕：开\"",
     "subtitle: 标签不再区分有无字幕源"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        fullscreen.reset()\n        if let previous = fileAccess.end() {",
     "        if let previous = fileAccess.end() {",
     "viewModel: 退出时不复位全屏"),
    ("Sources/PlayerUI/PlayerViewModel.swift",
     "        if let previous = fileAccess.begin(resource.url) {\n            previous.stopAccessingSecurityScopedResource()\n        }",
     "",
     "viewModel: 换文件时不申请访问权（外部文件读不到）"),
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


def swift_escape_args() -> list[str]:
    """受限 shell 里 macOS 不允许嵌套 apply 沙箱，SwiftPM 会直接失败；此处按需补逃逸参数。"""
    probe = subprocess.run(
        ["sandbox-exec", "-p", "(version 1)(deny default)(allow file-read*)", "/bin/echo", "ok"],
        capture_output=True,
    )
    return [] if probe.returncode == 0 else ["--disable-sandbox"]


def run_suite() -> str:
    try:
        result = subprocess.run(
            ["swift", "test", *swift_escape_args()],
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
