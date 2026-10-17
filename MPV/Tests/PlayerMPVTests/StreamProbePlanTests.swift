#if canImport(Libmpv)
import Foundation
import Testing

@testable import PlayerMPV

/// `StreamProbePlan`：探测窗口只对**实时投递**的源缩短（`P6-T4`）。
///
/// 纯逻辑单独测，因为这里有一条**很容易写反的规则**：
/// 缩短窗口能讨好起播，但窗口存在的意义是"让 lavf 看清流信息" ——
/// 对着按需拉取的源一起缩短，是拿没量到的好处换没量到的风险。
@Suite
struct StreamProbePlanTests {
    @Test("实时投递的协议 ⇒ 短窗口")
    func testRealtimeSchemesGetShortWindow() throws {
        let realtime = [
            "rtsp://192.0.2.10:8554/live",
            "rtsps://cam.local/stream",
            "rtmp://a.example.com/live/x",
            "rtmps://a.example.com/live/x",
            "srt://a.example.com:9000",
            "udp://239.0.0.1:1234",
        ]
        for raw in realtime {
            let url = try #require(URL(string: raw))
            #expect(
                StreamProbePlan(url).analyzeduration == StreamProbePlan.realtimeAnalyzeduration,
                "\(raw) 是实时投递，窗口会变成用户等待，必须缩短"
            )
        }
    }

    @Test("按需拉取的源 ⇒ 不动窗口")
    func testPullBasedSourcesKeepTheDefaultWindow() {
        let pullBased = [
            "http://192.0.2.10:8765/sintel_trailer-720p.mp4",
            "https://example.com/master.m3u8",
            "file:///tmp/clip.mp4",
        ]
        for raw in pullBased {
            #expect(
                StreamProbePlan(URL(string: raw)!).analyzeduration == nil,
                "\(raw) 不是实时投递 ⇒ 不该动窗口（缩短它没有可量到的收益）"
            )
        }
    }

    @Test("scheme 大小写不敏感")
    func testSchemeIsCaseInsensitive() throws {
        let upper = try #require(URL(string: "RTSP://192.0.2.10:8554/live"))
        #expect(
            StreamProbePlan(upper).analyzeduration == StreamProbePlan.realtimeAnalyzeduration,
            "`URL` 原样保留 scheme 大小写 ⇒ 不归一化会让规则静默失效"
        )
    }

    @Test("没有 scheme（相对路径 / 纯字符串）⇒ 不动窗口")
    func testMissingSchemeKeepsTheDefaultWindow() {
        #expect(StreamProbePlan(URL(fileURLWithPath: "/tmp/clip.mp4")).analyzeduration == nil)
        #expect(StreamProbePlan(URL(string: "clip.mp4")!).analyzeduration == nil)
    }

    @Test("短窗口必须**显著**短于默认 —— 否则这一项只是心理安慰")
    func testShortWindowIsActuallyShort() throws {
        let value = try #require(StreamProbePlan.realtimeAnalyzeduration)
        #expect(value <= 0.5, "实测默认窗口造成 1.1 s 等待；取值 0.2 s 是量出来的，不是拍的")
        #expect(value > 0, "0 会让 lavf 完全没有分析窗口，那不是缩短而是关掉")
    }
}
#endif
