import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

final class MediaWriter: @unchecked Sendable {
    /// Utility QoS so encode yields to UI / meeting audio under load.
    private let queue = DispatchQueue(label: "app.sauron.writer", qos: .utility)
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
    private var lastAcceptedVideoPTS = CMTime.invalid
    /// When true, a video frame is already being processed — drop newcomers instead of queueing CPU work.
    private var videoBusy = false
    private let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
    private var capturePixelFormat: OSType = MediaEncodePolicy.capturePixelFormat

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
        // Retain the sample, then process async so SCK isn't blocked on encode.
        queue.async { [weak self] in
            self?.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendMic(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareAudioInput(sampleBuffer, writer: self.micWriter, input: &self.micInput, label: "mic")
            self.append(sampleBuffer, writer: self.micWriter, input: self.micInput, started: &self.startedMic)
        }
    }

    func appendSystem(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareAudioInput(sampleBuffer, writer: self.systemWriter, input: &self.systemInput, label: "system")
            self.append(sampleBuffer, writer: self.systemWriter, input: self.systemInput, started: &self.startedSystem)
        }
    }

    func finish() async {
        await finish(videoWriter, input: videoInput, started: startedVideo)
        await finish(micWriter, input: micInput, started: startedMic)
        await finish(systemWriter, input: systemInput, started: startedSystem)
    }

    private func appendVideoOnQueue(_ sampleBuffer: CMSampleBuffer) {
        if MediaEncodePolicy.shouldDropAllLiveVideo { return }
        if videoBusy { return }
        videoBusy = true
        defer { videoBusy = false }

        prepareVideoInput(sampleBuffer)
        guard let writer = videoWriter, let input = videoInput else { return }
        beginSessionIfNeeded(writer: writer, sampleBuffer: sampleBuffer, started: &startedVideo)
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if shouldDropForFrameRate(time) { return }

        let srcW = CVPixelBufferGetWidth(imageBuffer)
        let srcH = CVPixelBufferGetHeight(imageBuffer)

        // Prefer direct append when SCK already matched our even encoder size.
        if srcW == videoWidth, srcH == videoHeight {
            if input.append(sampleBuffer) {
                lastAcceptedVideoPTS = time
            }
            return
        }

        // Hot / Low Power: skip CI rescale (CPU+GPU) rather than bogging the machine down.
        if MediaEncodePolicy.shouldAvoidCPUFrameConvert { return }

        appendConvertedFrame(imageBuffer, at: time)
        lastAcceptedVideoPTS = time
    }

    private func shouldDropForFrameRate(_ time: CMTime) -> Bool {
        guard lastAcceptedVideoPTS.isValid, time.isValid else { return false }
        let fps = max(1, MediaEncodePolicy.liveTargetFPS)
        let minInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        return CMTimeCompare(CMTimeSubtract(time, lastAcceptedVideoPTS), minInterval) < 0
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
        capturePixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        addVideoInput(to: writer, hint: nil)
    }

    private func addVideoInput(to writer: AVAssetWriter, hint: CMFormatDescription?) {
        let codecs: [AVVideoCodecType]
        if MediaEncodePolicy.prefersHEVC {
            codecs = [.hevc, .h264]
        } else {
            codecs = [.h264]
        }

        for codec in codecs {
            var compression = MediaEncodePolicy.videoCompressionProperties(
                codec: codec,
                width: videoWidth,
                height: videoHeight
            )
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }

            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: compression
            ]

            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { continue }

            let input: AVAssetWriterInput
            if let hint {
                input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: hint)
            } else {
                input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            }
            input.expectsMediaDataInRealTime = true
            input.performsMultiPassEncodingIfSupported = false
            guard writer.canAdd(input) else { continue }

            writer.add(input)
            videoInput = input
            videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(capturePixelFormat),
                    kCVPixelBufferWidthKey as String: videoWidth,
                    kCVPixelBufferHeightKey as String: videoHeight,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
            )
            return
        }
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
                capturePixelFormat,
                [
                    kCVPixelBufferMetalCompatibilityKey: true,
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
