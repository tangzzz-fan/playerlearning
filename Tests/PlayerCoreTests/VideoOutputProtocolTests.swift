import Testing
@testable import PlayerCore

/// 替身：只声明"句柄是什么"，别的什么都不做。
private final class StubOutput: VideoOutputProtocol {
    let windowEmbedHandle: Int64?

    init(windowEmbedHandle: Int64?) {
        self.windowEmbedHandle = windowEmbedHandle
    }
}

@Suite
struct VideoOutputProtocolTests {
    @Test
    func testHandleImpliesWindowEmbed() {
        #expect(StubOutput(windowEmbedHandle: 0x1234).kind == .windowEmbed)
    }

    @Test
    func testNoHandleImpliesRenderAPI() {
        #expect(StubOutput(windowEmbedHandle: nil).kind == .renderAPI)
    }

    /// 句柄为 `0` 也要算"有句柄"：`nil` 才是"没有"。
    /// 把 0 当成没有会静默改变输出结构 —— 而 0 在 C 世界里是完全合法的指针值风格。
    @Test
    func testZeroHandleIsStillAHandle() {
        #expect(StubOutput(windowEmbedHandle: 0).kind == .windowEmbed)
    }
}
