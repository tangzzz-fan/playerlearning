import Testing
@testable import PlayerCore

@Suite
struct PlaybackEndReasonTests {
    @Test
    func testEndOfStreamFinishes() {
        #expect(PlaybackEndReason.endOfStream.resultingState == .finished)
    }

    @Test
    func testErrorFails() {
        #expect(PlaybackEndReason.error.resultingState == .failed)
    }

    @Test
    func testStoppedGoesIdle() {
        #expect(PlaybackEndReason.stopped.resultingState == .idle)
    }

    @Test
    func testQuitReportsNoStateChange() {
        #expect(PlaybackEndReason.quit.resultingState == nil)
    }

    @Test
    func testRedirectReportsNoStateChange() {
        #expect(PlaybackEndReason.redirect.resultingState == nil)
    }

    @Test
    func testOnlyErrorReachesFailed() {
        for reason in PlaybackEndReason.allCases {
            #expect(
                (reason.resultingState == .failed) == (reason == .error),
                "\(reason) 只有 error 才应进入 .failed，否则「放完了」与「放失败了」会被混为一谈"
            )
        }
    }

    @Test
    func testOnlyQuitAndRedirectAreSilent() {
        for reason in PlaybackEndReason.allCases {
            let silent = reason.resultingState == nil
            #expect(silent == (reason == .quit || reason == .redirect), "\(reason) 的静默口径不正确")
        }
    }
}
