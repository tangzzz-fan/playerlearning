import Foundation
import Testing
@testable import PlayerUI

@Suite
struct PlayerSecurityScopedAccessTests {
    private let first = URL(fileURLWithPath: "/tmp/one.mkv")
    private let second = URL(fileURLWithPath: "/tmp/two.mkv")

    @Test
    func testStartsEmpty() {
        let access = PlayerSecurityScopedAccess()

        #expect(access.active == nil)
    }

    @Test
    func testBeginTracksActiveURLAndReportsNothingToStopFirst() {
        var access = PlayerSecurityScopedAccess()

        let toStop = access.begin(first)

        #expect(access.active == first)
        #expect(toStop == nil, "第一次没有旧文件要释放")
    }

    /// ⚠️ 换文件时必须**把旧的还回来**让调用方释放 —— 漏掉就泄漏。
    @Test
    func testBeginOnAnotherURLReportsPrevious() {
        var access = PlayerSecurityScopedAccess()
        _ = access.begin(first)

        let toStop = access.begin(second)

        #expect(toStop == first, "换文件要返回上一个 URL 供调用方 stop")
        #expect(access.active == second)
    }

    /// 重复 begin 同一个 URL **不能**再 start 一次（否则 start/stop 计数对不上）。
    @Test
    func testBeginOnSameURLIsIdempotent() {
        var access = PlayerSecurityScopedAccess()
        _ = access.begin(first)

        let toStop = access.begin(first)

        #expect(toStop == nil, "同一个文件不该重复申请访问权")
        #expect(access.active == first)
    }

    @Test
    func testEndReportsAndClears() {
        var access = PlayerSecurityScopedAccess()
        _ = access.begin(first)

        let toStop = access.end()

        #expect(toStop == first)
        #expect(access.active == nil)
        #expect(access.end() == nil, "重复结束不该再还一个 URL 出来")
    }
}
