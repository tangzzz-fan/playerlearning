#if canImport(Libmpv)
import Testing

@testable import PlayerMPV

/// `RequestHeaders`：把 `PlayerResource.headers` 翻成 mpv 能吃的两种形态。
///
/// 单独拎出来做纯逻辑，是因为这里有两个**只能靠断言钉死**的点：
/// ① `http-header-fields` 的**顺序**（字典无序 ⇒ 不排序就每次都不一样，日志与断言都失去可比性）；
/// ② `User-Agent` 的**单源**（它同时能以 `user-agent` 选项和 `http-header-fields` 里的一项出现，
///    两个来源打架时"到底发了哪个"没人说得清）。
@Suite
struct RequestHeadersTests {
    @Test("没有自定义头 ⇒ 两个取值都不给，避免设一个空选项")
    func testEmptyHeadersProduceNothing() {
        let plan = RequestHeaders([:])
        #expect(plan.userAgent == nil)
        #expect(plan.headerFields == nil)
    }

    @Test("单个头 ⇒ mpv 的 `Key: Value` 形态")
    func testSingleHeader() {
        let plan = RequestHeaders(["X-Player-Test": "yes"])
        #expect(plan.headerFields == "X-Player-Test: yes")
        #expect(plan.userAgent == nil)
    }

    @Test("多个头 ⇒ 按 key 排序后逗号分隔（顺序必须确定）")
    func testMultipleHeadersAreSorted() {
        let plan = RequestHeaders(["X-B": "2", "X-A": "1", "Referer": "http://example.com"])
        #expect(plan.headerFields == "Referer: http://example.com,X-A: 1,X-B: 2")
    }

    @Test("User-Agent 走 `user-agent`，且**不再重复**出现在 header-fields 里")
    func testUserAgentIsSingleSourced() {
        let plan = RequestHeaders(["User-Agent": "PlayerStack-Test/2.0", "X-A": "1"])
        #expect(plan.userAgent == "PlayerStack-Test/2.0")
        #expect(plan.headerFields == "X-A: 1")
    }

    @Test("User-Agent 任意大小写都认得出来")
    func testUserAgentKeyIsCaseInsensitive() {
        #expect(RequestHeaders(["user-agent": "lower/1"]).userAgent == "lower/1")
        #expect(RequestHeaders(["USER-AGENT": "upper/1"]).userAgent == "upper/1")
        #expect(RequestHeaders(["user-agent": "lower/1"]).headerFields == nil)
    }

    @Test("只有 User-Agent 时不给 header-fields（空字符串会变成「我配过了」的错觉）")
    func testUserAgentAloneLeavesHeaderFieldsEmpty() {
        #expect(RequestHeaders(["User-Agent": "only/1"]).headerFields == nil)
    }

    @Test("key 为空白的项丢掉 —— 否则生成的是 `: value` 这种垃圾")
    func testBlankKeysAreDropped() {
        let plan = RequestHeaders(["": "orphan", "   ": "blank", "X-A": "1"])
        #expect(plan.headerFields == "X-A: 1")
    }
}
#endif
