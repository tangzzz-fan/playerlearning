import Testing
@testable import PlayerCore

@Suite
struct VideoEffectTests {
    @Test
    func testShaderIndexMatchesShaderConstants() {
        // ⚠️ 这两个数字是**跨语言契约**：一个是 Swift 枚举，一个是 MSL 里的 `if (effect == 1)`。
        // 改任何一边都会让"切了效果但画面不变"，而那种画面**看起来完全正常**。
        #expect(VideoEffect.none.shaderIndex == 0)
        #expect(VideoEffect.mono.shaderIndex == 1)
    }

    @Test
    func testNextCyclesThroughEveryCase() {
        var seen: [VideoEffect] = []
        var current = VideoEffect.none
        for _ in 0 ..< VideoEffect.allCases.count {
            seen.append(current)
            current = current.next
        }

        #expect(seen == VideoEffect.allCases)
        #expect(current == .none, "循环必须回到起点，否则调试入口按几下就出不来了")
    }

    @Test
    func testLabelsAreNotEmpty() {
        for effect in VideoEffect.allCases {
            #expect(!effect.label.isEmpty)
        }
    }
}
