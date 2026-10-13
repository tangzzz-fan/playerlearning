import Testing
@testable import PlayerCore

@Suite
struct PlayerAudioStateTests {
    @Test
    func testStartsSilentOnBothSides() {
        let state = PlayerAudioState()

        #expect(state.decoderSampleRate == 0)
        #expect(state.outputSampleRate == 0)
        #expect(!state.isDecoding)
        #expect(!state.isOutputting)
    }

    @Test
    func testDecoderRateChangeIsReported() throws {
        var state = PlayerAudioState()

        let reported = state.setDecoderSampleRate(44100)
        let next = try #require(reported)

        #expect(next.decoderSampleRate == 44100)
        #expect(next.isDecoding)
    }

    @Test
    func testOutputRateChangeIsReported() throws {
        var state = PlayerAudioState()

        let reported = state.setOutputSampleRate(48000)
        let next = try #require(reported)

        #expect(next.outputSampleRate == 48000)
        #expect(next.isOutputting)
    }

    @Test
    func testSameRateProducesNoUpdate() {
        var state = PlayerAudioState()
        _ = state.setDecoderSampleRate(44100)

        #expect(state.setDecoderSampleRate(44100) == nil, "重复的同值不应上报")
        #expect(state.setOutputSampleRate(0) == nil, "0 → 0 也不应上报")
    }

    @Test
    func testDecoderAndOutputAreIndependent() {
        var state = PlayerAudioState()

        _ = state.setDecoderSampleRate(44100)

        #expect(state.isDecoding, "解出了采样率就说明有音轨在解码")
        #expect(!state.isOutputting, "⚠️ 解码 ≠ 出声：输出端未建立时 isOutputting 必须为 false")
    }

    @Test
    func testResettingToZeroIsReported() throws {
        var state = PlayerAudioState()
        _ = state.setOutputSampleRate(44100)

        let reported = state.setOutputSampleRate(0)
        let next = try #require(reported)

        #expect(next.outputSampleRate == 0)
        #expect(!next.isOutputting, "切到无音轨的文件时必须能上报\"音频没了\"")
    }

    @Test
    func testOnlyPositiveRatesCountAsActive() {
        var state = PlayerAudioState()

        _ = state.setDecoderSampleRate(-1)
        _ = state.setOutputSampleRate(-1)

        #expect(!state.isDecoding)
        #expect(!state.isOutputting)
    }
}
