import XCTest
@testable import PlayerCore

final class PlayerResourceTests: XCTestCase {
    func testHeadersDefaultToEmpty() {
        let resource = PlayerResource(url: URL(fileURLWithPath: "/tmp/sample.mkv"))
        XCTAssertTrue(resource.headers.isEmpty)
    }

    func testEqualWhenURLAndHeadersMatch() {
        let url = URL(string: "https://example.com/stream.m3u8")!
        XCTAssertEqual(PlayerResource(url: url, headers: ["A": "1"]), PlayerResource(url: url, headers: ["A": "1"]))
    }

    func testNotEqualWhenHeadersDiffer() {
        let url = URL(string: "https://example.com/stream.m3u8")!
        XCTAssertNotEqual(PlayerResource(url: url), PlayerResource(url: url, headers: ["A": "1"]))
    }

    func testNotEqualWhenURLDiffers() {
        let headers = ["A": "1"]
        let first = PlayerResource(url: URL(fileURLWithPath: "/tmp/a.mkv"), headers: headers)
        let second = PlayerResource(url: URL(fileURLWithPath: "/tmp/b.mkv"), headers: headers)
        XCTAssertNotEqual(first, second)
    }
}
