import CoreGraphics
import PlayerCore
import QuartzCore
import XCTest
@testable import PlayerUI

private nonisolated(unsafe) let sharedOutput = WindowEmbedOutput()

final class WindowEmbedOutputTests: XCTestCase {
    func testConformsToVideoOutputProtocol() {
        let output: any VideoOutputProtocol = WindowEmbedOutput()

        XCTAssertNotNil(output.windowEmbedHandle)
    }

    func testDistinctInstancesExposeDistinctHandles() {
        let first = WindowEmbedOutput()
        let second = WindowEmbedOutput()

        XCTAssertNotEqual(first.windowEmbedHandle, second.windowEmbedHandle)
    }

    func testHandleMatchesInstancePointer() {
        let output = WindowEmbedOutput()
        let expected = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(output).toOpaque())))

        XCTAssertEqual(output.windowEmbedHandle, expected)
    }

    func testAcceptsUsableDrawableSize() {
        let output = WindowEmbedOutput()

        output.drawableSize = CGSize(width: 1920, height: 1080)

        XCTAssertEqual(output.drawableSize, CGSize(width: 1920, height: 1080))
    }

    func testRejectsDegenerateDrawableSizeKeepingPreviousValue() {
        let output = WindowEmbedOutput()
        output.drawableSize = CGSize(width: 1920, height: 1080)

        output.drawableSize = CGSize(width: 1, height: 1)

        XCTAssertEqual(output.drawableSize, CGSize(width: 1920, height: 1080))
    }

    func testRejectsSizeWithSingleDegenerateWidth() {
        let output = WindowEmbedOutput()
        output.drawableSize = CGSize(width: 1920, height: 1080)

        output.drawableSize = CGSize(width: 0, height: 1080)

        XCTAssertEqual(output.drawableSize, CGSize(width: 1920, height: 1080))
    }

    func testRejectsSizeWithSingleDegenerateHeight() {
        let output = WindowEmbedOutput()
        output.drawableSize = CGSize(width: 1920, height: 1080)

        output.drawableSize = CGSize(width: 1920, height: 1)

        XCTAssertEqual(output.drawableSize, CGSize(width: 1920, height: 1080))
    }

    func testAcceptsSizeWithExactlyTwoPoints() {
        let output = WindowEmbedOutput()

        output.drawableSize = CGSize(width: 2, height: 2)

        XCTAssertEqual(output.drawableSize, CGSize(width: 2, height: 2))
    }

    func testExtendedDynamicRangeIsSettableFromBackgroundThread() {
        let done = expectation(description: "background set")

        DispatchQueue.global().async {
            sharedOutput.wantsExtendedDynamicRangeContent = true
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        XCTAssertTrue(sharedOutput.wantsExtendedDynamicRangeContent)
    }
}
