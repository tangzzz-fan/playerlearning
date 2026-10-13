import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// 现场生成一个确定性样例片段，写进 App 沙盒。
///
/// ⚠️ **2026-10-14 起它的角色变成「离线兜底」**：正常路径是 `SampleClipProvider`
/// 下载真实视频（MDN `flower.mp4`，CC0），只有下载不到时才落到这里。
/// 保留它的理由很具体：**端到端门禁不能依赖网络** —— 断网时若没有兜底，
/// `G2` 会因为"素材拿不到"而失败，而那是环境问题、不是代码问题，会被误读成回归。
///
/// 它仍然生成**真的 AAC 音轨**，所以离线时「出声」这一项依然有证据。
/// 二进制不入仓库的立场不变（与 `vendor/ksplayer` 剔除 99 MB 闭源 xcframework 一致）。
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
        case muxFailed(String)
    }

    /// 音轨参数 —— **必须真的可解码、能出声**，否则"出声"这一项就没有证据（`G2` 的最后一项）。
    static let toneHz = 440.0
    static let sampleRate = 44100.0

    /// 幂等：已存在就不重复生成。
    static func ensureClip() async throws -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sample-\(width)x\(height)-\(Int(duration))s-a.mp4")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        try await makeClip(at: url)
        return url
    }

    /// 视频 + 音频分头生成，再**封装**成交付文件。
    ///
    /// 为什么分两步而不是直接往 `AVAssetWriter` 里塞 `CMSampleBuffer`：
    /// `AVAudioFile(forWriting:settings:)` 会**替我们做 AAC 编码与格式转换**，
    /// 省掉手工拼 `CMSampleBuffer` / `CMBlockBuffer` / ASBD 那一大段（也就省掉那一类错）。
    /// 视频轨走 `AVAssetWriter`（需要逐帧像素缓冲），音频轨走 `AVAudioFile`，最后 `AVMutableComposition`
    /// **无损封装**（`Passthrough`，不重新编码）。
    private static func makeClip(at output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
        let videoOnly = directory.appendingPathComponent(UUID().uuidString + "-v.mp4")
        let audioOnly = directory.appendingPathComponent(UUID().uuidString + "-a.m4a")
        defer {
            try? FileManager.default.removeItem(at: videoOnly)
            try? FileManager.default.removeItem(at: audioOnly)
        }

        try await writeVideo(to: videoOnly)
        try writeAudio(to: audioOnly)
        try await mux(video: videoOnly, audio: audioOnly, to: output)
    }

    private static func writeAudio(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleRate * duration)
              )
        else {
            throw Failure.contextUnavailable
        }
        buffer.frameLength = buffer.frameCapacity
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0 ..< Int(buffer.frameLength) {
                let seconds = Double(frame) / sampleRate
                samples[frame] = Float(sin(2 * .pi * toneHz * seconds) * 0.2)
            }
        }
        try file.write(from: buffer)
    }

    private static func mux(video: URL, audio: URL, to output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let composedVideo = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ),
              let composedAudio = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw Failure.muxFailed("拿不到视频轨或音频轨")
        }

        let span = CMTimeRange(
            start: .zero,
            duration: try await videoAsset.load(.duration)
        )
        try composedVideo.insertTimeRange(span, of: videoTrack, at: .zero)
        try composedAudio.insertTimeRange(span, of: audioTrack, at: .zero)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw Failure.muxFailed("拿不到导出会话")
        }
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .mp4)
    }

    private static func writeVideo(to url: URL) async throws {
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
