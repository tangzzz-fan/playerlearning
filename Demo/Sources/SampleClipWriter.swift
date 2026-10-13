import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// 现场生成一个确定性样例片段，写进 App 沙盒。
///
/// 为什么不随包带一个样片：二进制不入仓库（`.gitignore` 的立场与 `vendor/ksplayer`
/// 剔除 99 MB 闭源 xcframework 一致），也不在运行时下载（本机出网要过 MITM 代理）。
enum SampleClipWriter {
    static let width = 640
    static let height = 360
    static let fps: Int32 = 24
    static let duration = 5.0

    enum Failure: Error {
        case writerUnavailable(Error?)
        case pixelBufferPoolUnavailable
        case pixelBufferUnavailable
        case contextUnavailable
        case encoderRejectedFrame(Int)
    }

    /// 幂等：已存在就不重复生成。
    static func ensureClip() async throws -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sample-\(width)x\(height)-\(Int(duration))s.mp4")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        try await write(to: url)
        return url
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

        context.setFillColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let progress = CGFloat(frame) / CGFloat(max(1, Int(duration * Double(fps)) - 1))
        context.setFillColor(red: 0.98, green: 0.62, blue: 0.12, alpha: 1)
        context.fill(CGRect(x: progress * CGFloat(width - 80), y: 120, width: 80, height: 120))
        return buffer
    }
}
