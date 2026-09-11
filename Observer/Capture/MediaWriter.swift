import AVFoundation
import CoreMedia
import Foundation

final class MediaWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.observer.writer")
    private var videoWriter: AVAssetWriter?
    private var micWriter: AVAssetWriter?
    private var systemWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var startedVideo = false
    private var startedMic = false
    private var startedSystem = false

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
            append(sampleBuffer, writer: videoWriter, input: videoInput, started: &startedVideo)
        }
    }

    func appendMic(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            prepareAudioInput(sampleBuffer, writer: micWriter, input: &micInput)
            append(sampleBuffer, writer: micWriter, input: micInput, started: &startedMic)
        }
    }

    func appendSystem(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            prepareAudioInput(sampleBuffer, writer: systemWriter, input: &systemInput)
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
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: 20,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
            videoInput = input
        }
    }

    private func prepareAudioInput(
        _ sampleBuffer: CMSampleBuffer,
        writer: AVAssetWriter?,
        input: inout AVAssetWriterInput?
    ) {
        guard input == nil, let writer else { return }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let sampleRate = asbd?.mSampleRate ?? 48_000
        let channels = Int(asbd?.mChannelsPerFrame ?? 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: max(channels, 1),
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
            input = audioInput
        }
    }

    private func append(
        _ sampleBuffer: CMSampleBuffer,
        writer: AVAssetWriter?,
        input: AVAssetWriterInput?,
        started: inout Bool
    ) {
        guard let writer, let input else { return }
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
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
}
