#if canImport(Libmpv)
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// **现场生成**确定性素材。
///
/// 为什么不往仓库里放一个样片、也不在测试里下载：
/// ① 二进制不入仓库（本项目连 99 MB 的闭源 xcframework 都剔除了）；
/// ② 测试不得依赖网络 —— 本机出网要过 MITM 代理，`P-002` 已经记过下载被静默截断的坑；
/// ③ 夹具必须确定性（`P-033`）：尺寸、时长、帧率都由常量决定，不随环境变。
enum TestClip {
    static let width = 320
    static let height = 240
    static let fps: Int32 = 10
    static let duration = 2.0

    enum Failure: Error {
        case writerUnavailable(Error?)
        case pixelBufferPoolUnavailable
        case pixelBufferUnavailable
        case contextUnavailable
        case encoderRejectedFrame(Int)
    }

    /// 写一个时长 `duration` 秒的 H.264 mp4 到临时目录，返回其 URL。
    static func makeURL() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playerlearning-\(UUID().uuidString).mp4")
        try await write(to: url)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(input) else { throw Failure.writerUnavailable(writer.error) }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writerUnavailable(writer.error) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0 ..< Int(duration * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let buffer = try makePixelBuffer(frame: frame, pool: adaptor.pixelBufferPool)
            let accepted = adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)
            )
            guard accepted else { throw Failure.encoderRejectedFrame(frame) }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writerUnavailable(writer.error) }
    }

    private static func makePixelBuffer(frame: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        guard let pool else { throw Failure.pixelBufferPoolUnavailable }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure.pixelBufferUnavailable }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw Failure.contextUnavailable
        }

        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: frame * 12 % width, y: 80, width: 40, height: 80))

        return buffer
    }
}
#endif
