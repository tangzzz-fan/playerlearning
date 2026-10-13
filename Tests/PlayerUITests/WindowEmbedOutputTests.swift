import CoreGraphics
import PlayerCore
import QuartzCore
import Testing
@testable import PlayerUI

private nonisolated(unsafe) let sharedOutput = WindowEmbedOutput()

@Suite(.serialized)
struct WindowEmbedOutputTests {
    @Test
    func testConformsToVideoOutputProtocol() {
        let output: any VideoOutputProtocol = WindowEmbedOutput()

        #expect(output.windowEmbedHandle != nil)
    }

    @Test
    func testDistinctInstancesExposeDistinctHandles() {
        let first = WindowEmbedOutput()
        let second = WindowEmbedOutput()

        #expect(first.windowEmbedHandle != second.windowEmbedHandle)
    }

    @Test
    func testHandleMatchesInstancePointer() {
        let output = WindowEmbedOutput()
        let expected = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(output).toOpaque())))

        #expect(output.windowEmbedHandle == expected)
    }

    @Test
    func testAcceptsUsableDrawableSize() {
        let output = WindowEmbedOutput()

        output.drawableSize = CGSize(width: 1920, height: 1080)

        #expect(output.drawableSize == CGSize(width: 1920, height: 1080))
    }

    @Test
    func testRejectsDegenerateDrawableSizeKeepingPreviousValue() {
        let output = WindowEmbedOutput()
        output.drawableSize = CGSize(width: 1920, height: 1080)

        output.drawableSize = CGSize(width: 1, height: 1)

        #expect(output.drawableSize == CGSize(width: 1920, height: 1080))
    }

    @Test
    func testRejectsSizeWithSingleDegenerateWidth() {
        let output = WindowEmbedOutput()
        output.drawableSize = CGSize(width: 1920, height: 1080)

        output.drawableSize = CGSize(width: 0, height: 1080)

        #expect(output.drawableSize == CGSize(width: 1920, height: 1080))
    }

    @Test
    func testRejectsSizeWithSingleDegenerateHeight() {
        let output = WindowEmbedOutput()
        output.drawableSize = CGSize(width: 1920, height: 1080)

        output.drawableSize = CGSize(width: 1920, height: 1)

        #expect(output.drawableSize == CGSize(width: 1920, height: 1080))
    }

    @Test
    func testAcceptsSizeWithExactlyTwoPoints() {
        let output = WindowEmbedOutput()

        output.drawableSize = CGSize(width: 2, height: 2)

        #expect(output.drawableSize == CGSize(width: 2, height: 2))
    }

    @Test
    func testExtendedDynamicRangeIsSettableFromBackgroundThread() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                sharedOutput.wantsExtendedDynamicRangeContent = true
                continuation.resume()
            }
        }

        #expect(sharedOutput.wantsExtendedDynamicRangeContent)
    }
}
