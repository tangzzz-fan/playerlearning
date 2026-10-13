import Foundation
import Testing
@testable import PlayerCore

@Suite
struct PlayerResourceTests {
    @Test
    func testHeadersDefaultToEmpty() {
        let resource = PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv"))
        #expect(resource.headers.isEmpty)
    }

    @Test
    func testEqualWhenURLAndHeadersMatch() throws {
        let url = try #require(URL(string: "https://example.com/stream.m3u8"))
        #expect(PlayerResource(url: url, headers: ["A": "1"]) == PlayerResource(url: url, headers: ["A": "1"]))
    }

    @Test
    func testNotEqualWhenHeadersDiffer() throws {
        let url = try #require(URL(string: "https://example.com/stream.m3u8"))
        #expect(PlayerResource(url: url) != PlayerResource(url: url, headers: ["A": "1"]))
    }

    @Test
    func testNotEqualWhenURLDiffers() {
        let headers = ["A": "1"]
        let first = PlayerResource(url: URL(fileURLWithPath: "/tmp/a.mkv"), headers: headers)
        let second = PlayerResource(url: URL(fileURLWithPath: "/tmp/b.mkv"), headers: headers)
        #expect(first != second)
    }
}
