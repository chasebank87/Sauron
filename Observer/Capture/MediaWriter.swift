import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

final class MediaWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.observer.writer")
    private var videoWriter: AVAssetWriter?
    private var micWriter: AVAssetWriter?
    private var systemWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoWidth = 0
    private var videoHeight = 0
    private var micInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var startedVideo = false
    private var startedMic = false
    private var startedSystem = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    let videoURL: URL?
    let micURL: URL?
    let systemURL: URL?

    init(folder: URL, includeVideo: Bool, includeAudio: Bool) {
        videoURL = includeVideo ? folder.appending(path: "video.mp4") : nil
        micURL = includeAudio ? folder.appending(path: "mic.m4a") : nil
        systemURL = includeAudio ? folder.appending(path: "system.m4a") : nil

        if let videoURL {
            try? FileManager.default.removeItem(at: videoURL)
            videoWriter = try? AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        }
        if let micURL {
            try? FileManager.default.removeItem(at: micURL)
            micWriter = try? AVAssetWriter(outputURL: micURL, fileType: .m4a)
        }
        if let systemURL {
            try? FileManager.default.removeItem(at: systemURL)
            systemWriter = try? AVAssetWriter(outputURL: systemURL, fileType: .m4a)
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            prepareVideoInput(sampleBuffer)
            guard let writer = videoWriter, let input = videoInput else { return }
            beginSessionIfNeeded(writer: writer, sampleBuffer: sampleBuffer, started: &startedVideo)
            guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let srcW = CVPixelBufferGetWidth(imageBuffer)
            let srcH = CVPixelBufferGetHeight(imageBuffer)
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Prefer direct append when SCK already matched our even encoder size.
            if srcW == videoWidth, srcH == videoHeight {
                _ = input.append(sampleBuffer)
                return
            }

            // Otherwise convert/crop through CI — raw memcpy was producing black frames
            // when the ScreenCaptureKit buffer layout/format didn't match BGRA tightly.
            appendConvertedFrame(imageBuffer, at: time)
        }
    }

    func appendMic(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            prepareAudioInput(sampleBuffer, writer: micWriter, input: &micInput, label: "mic")
            append(sampleBuffer, writer: micWriter, input: micInput, started: &startedMic)
        }
    }

    func appendSystem(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            prepareAudioInput(sampleBuffer, writer: systemWriter, input: &systemInput, label: "system")
            append(sampleBuffer, writer: systemWriter, input: systemInput, started: &startedSystem)
        }
    }

    func finish() async {
        await finish(videoWriter, input: videoInput, started: startedVideo)
        await finish(micWriter, input: micInput, started: startedMic)
        await finish(systemWriter, input: systemInput, started: startedSystem)
    }

    private func prepareVideoInput(_ sampleBuffer: CMSampleBuffer) {
        guard videoInput == nil, let writer = videoWriter else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            videoWidth = evenPixelDimension(Int(dimensions.width))
            videoHeight = evenPixelDimension(Int(dimensions.height))
            addVideoInput(to: writer, hint: format)
            return
        }

        videoWidth = evenPixelDimension(CVPixelBufferGetWidth(imageBuffer))
        videoHeight = evenPixelDimension(CVPixelBufferGetHeight(imageBuffer))
        addVideoInput(to: writer, hint: nil)
    }

    private func addVideoInput(to writer: AVAssetWriter, hint: CMFormatDescription?) {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, videoWidth * videoHeight * 6),
                AVVideoExpectedSourceFrameRateKey: 20,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 40
            ]
        ]
        let input: AVAssetWriterInput
        if let hint {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: hint)
        } else {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        videoInput = input
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )
    }

    private func appendConvertedFrame(_ source: CVPixelBuffer, at time: CMTime) {
        guard let adaptor = videoAdaptor else { return }

        var output: CVPixelBuffer?
        let status: CVReturn
        if let pool = adaptor.pixelBufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        } else {
            status = CVPixelBufferCreate(
                nil,
                videoWidth,
                videoHeight,
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
                ] as CFDictionary,
                &output
            )
        }
        guard status == kCVReturnSuccess, let output else { return }

        let sourceImage = CIImage(cvPixelBuffer: source)
        let srcW = CGFloat(CVPixelBufferGetWidth(source))
        let srcH = CGFloat(CVPixelBufferGetHeight(source))
        let scaleX = CGFloat(videoWidth) / max(srcW, 1)
        let scaleY = CGFloat(videoHeight) / max(srcH, 1)
        let scaled = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(
            scaled,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        _ = adaptor.append(output, withPresentationTime: time)
    }

    private func prepareAudioInput(
        _ sampleBuffer: CMSampleBuffer,
        writer: AVAssetWriter?,
        input: inout AVAssetWriterInput?,
        label: String
    ) {
        guard input == nil, let writer else { return }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0
        else {
            // Wait for a well-formed buffer — early SCK mic frames can be incomplete.
            return
        }
        let sampleRate = Self.aacSampleRate(asbd.mSampleRate)
        let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 128_000 : 64_000
        ]

        // Prefer no format hint for mic — SCK mic ASBDs often disagree with AAC settings
        // and produce a writer that accepts startWriting but rejects every append (0-byte file).
        let ordered: [AVAssetWriterInput]
        if label == "mic" {
            ordered = [
                AVAssetWriterInput(mediaType: .audio, outputSettings: settings),
                AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            ]
        } else {
            ordered = [
                AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format),
                AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            ]
        }
        for candidate in ordered {
            candidate.expectsMediaDataInRealTime = true
            if writer.canAdd(candidate) {
                writer.add(candidate)
                input = candidate
                return
            }
        }
    }

    private func append(
        _ sampleBuffer: CMSampleBuffer,
        writer: AVAssetWriter?,
        input: AVAssetWriterInput?,
        started: inout Bool
    ) {
        guard let writer, let input else { return }
        beginSessionIfNeeded(writer: writer, sampleBuffer: sampleBuffer, started: &started)
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer), writer.status == .failed {
            // Mic format mismatches can fail the writer after start; leave file for diagnosis.
            return
        }
    }

    private func beginSessionIfNeeded(
        writer: AVAssetWriter,
        sampleBuffer: CMSampleBuffer,
        started: inout Bool
    ) {
        guard writer.status == .unknown else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !pts.isValid || pts.seconds.isNaN || pts.seconds < 0 {
            pts = .zero
        }
        guard writer.startWriting(), writer.status == .writing else { return }
        writer.startSession(atSourceTime: pts)
        started = true
    }

    private static func aacSampleRate(_ rate: Double) -> Double {
        let allowed: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        guard rate.isFinite, rate > 0 else { return 48_000 }
        return allowed.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 48_000
    }

    private func finish(_ writer: AVAssetWriter?, input: AVAssetWriterInput?, started: Bool) async {
        guard let writer else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                input?.markAsFinished()
                guard started, writer.status == .writing else {
                    if writer.status == .unknown {
                        writer.cancelWriting()
                    }
                    continuation.resume()
                    return
                }
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }
    }

    private func evenPixelDimension(_ value: Int) -> Int {
        let floored = max(2, value)
        return floored - (floored % 2)
    }
}
