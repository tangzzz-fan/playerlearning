import CoreGraphics
import Testing
@testable import PlayerCore

@Suite
struct VideoFitRectTests {
    @Test
    func testSameAspectFillsContainerExactly() {
        let rect = VideoFitRect.rect(
            content: CGSize(width: 1920, height: 1080),
            in: CGSize(width: 1280, height: 720),
            fit: .fit
        )

        #expect(rect == CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    @Test
    func testWideContentLetterboxesVertically() {
        // 2.39:1 的片放进 16:9 的容器 ⇒ 上下黑边，宽度占满。
        let rect = VideoFitRect.rect(
            content: CGSize(width: 1920, height: 800),
            in: CGSize(width: 1920, height: 1080),
            fit: .fit
        )

        #expect(rect.width == 1920)
        #expect(abs(rect.height - 800) < 0.001)
        #expect(abs(rect.minY - 140) < 0.001, "上下应各留 140 —— 居中不是差不多居中")
    }

    @Test
    func testTallContentPillarboxesHorizontally() {
        let rect = VideoFitRect.rect(
            content: CGSize(width: 1080, height: 1920),
            in: CGSize(width: 1920, height: 1080),
            fit: .fit
        )

        #expect(rect.height == 1080)
        #expect(abs(rect.width - 607.5) < 0.001)
        #expect(abs(rect.minX - 656.25) < 0.001)
    }

    @Test
    func testFillOverflowsContainerOnTheShortSide() {
        let rect = VideoFitRect.rect(
            content: CGSize(width: 1920, height: 800),
            in: CGSize(width: 1920, height: 1080),
            fit: .fill
        )

        // 铺满 ⇒ 高度顶满，宽度按同比例放大到超过容器（这正是"裁边"的来源）。
        #expect(rect.height == 1080)
        #expect(abs(rect.width - 2592) < 0.001)
        #expect(abs(rect.minX - (-336)) < 0.001)
    }

    @Test
    func testStretchIgnoresAspect() {
        let rect = VideoFitRect.rect(
            content: CGSize(width: 1920, height: 800),
            in: CGSize(width: 640, height: 640),
            fit: .stretch
        )

        #expect(rect == CGRect(x: 0, y: 0, width: 640, height: 640))
    }

    @Test
    func testZeroContainerProducesEmptyRect() {
        let rect = VideoFitRect.rect(
            content: CGSize(width: 1920, height: 1080),
            in: .zero,
            fit: .fit
        )

        #expect(rect == .zero)
    }

    @Test
    func testUnknownContentFillsContainerInsteadOfCollapsing() {
        // ⚠️ 方向与上一条相反：内容尺寸未知（起播第一拍就是 0×0）时**必须铺满**。
        // 按 0 处理会得到一个零尺寸矩形 —— 画面直接消失，而且没有任何报错。
        let rect = VideoFitRect.rect(content: .zero, in: CGSize(width: 800, height: 600), fit: .fit)

        #expect(rect == CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test
    func testNegativeContentAlsoFillsContainer() {
        let rect = VideoFitRect.rect(
            content: CGSize(width: -1920, height: 1080),
            in: CGSize(width: 800, height: 600),
            fit: .fit
        )

        #expect(rect.width == 800)
        #expect(rect.height == 600)
    }

    @Test
    func testNonFiniteInputsAreRejected() {
        let content = VideoFitRect.rect(
            content: CGSize(width: CGFloat.nan, height: 1080),
            in: CGSize(width: 800, height: 600),
            fit: .fit
        )
        let container = VideoFitRect.rect(
            content: CGSize(width: 16, height: 9),
            in: CGSize(width: CGFloat.infinity, height: 600),
            fit: .fit
        )

        #expect(content.width == 800 && content.height == 600)
        #expect(container == .zero)
    }

    @Test
    func testAspectRatioIsPreservedForFit() {
        for width in [320, 640, 1280, 3840] {
            let rect = VideoFitRect.rect(
                content: CGSize(width: width, height: width * 9 / 16),
                in: CGSize(width: 1000, height: 500),
                fit: .fit
            )
            #expect(abs(rect.width / rect.height - 16.0 / 9.0) < 0.0001)
        }
    }
}

@Suite
struct VideoFitScaledSizeTests {
    @Test
    func testNeverUpscalesABiggerContainer() {
        let size = VideoFitRect.scaledSize(
            content: CGSize(width: 1280, height: 720),
            in: CGSize(width: 3840, height: 2160)
        )

        #expect(size == CGSize(width: 1280, height: 720))
    }

    @Test
    func testShrinksToFitTheShortSide() {
        // 4K 源放进 1206×678 的图层：高度先绑定（678/2160 略小于 1206/3840），
        // 宽度随之取整到 1205 —— **取整方向不是重点，"不超过容器"才是**。
        let size = VideoFitRect.scaledSize(
            content: CGSize(width: 3840, height: 2160),
            in: CGSize(width: 1206, height: 678)
        )

        #expect(size.height == 678)
        #expect(size.width == 1205, "3840 × (678/2160) = 1205.33 ⇒ 取整 1205")
        #expect(size.width <= 1206)
    }

    @Test
    func testKeepsAspectWhenOnlyOneSideBinds() {
        // 2.39:1 的片放进 16:9 的图层：高度是约束，宽度随之变小。
        let size = VideoFitRect.scaledSize(
            content: CGSize(width: 3840, height: 1600),
            in: CGSize(width: 1920, height: 1080)
        )

        #expect(size.width == 1920)
        #expect(size.height == 800)
    }

    @Test
    func testDegenerateInputsPassThrough() {
        let content = CGSize(width: 1920, height: 1080)
        #expect(VideoFitRect.scaledSize(content: .zero, in: CGSize(width: 100, height: 100)) == .zero)
        #expect(VideoFitRect.scaledSize(content: content, in: .zero) == content)
    }

    @Test
    func testNeverCollapsesToZeroPixels() {
        // 极端窄的容器：四舍五入可能把某一边算成 0，那会让 CVPixelBufferCreate 失败。
        let size = VideoFitRect.scaledSize(
            content: CGSize(width: 1920, height: 1080),
            in: CGSize(width: 1, height: 600)
        )

        #expect(size.width >= 1)
        #expect(size.height >= 1)
    }
}
