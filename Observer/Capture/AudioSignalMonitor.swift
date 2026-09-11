import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import Observation

@Observable
@MainActor
final class AudioSignalMonitor {
    private(set) var micLevel: Float = 0
    private(set) var remoteLevel: Float = 0
    private(set) var micSilent = false
    private(set) var remoteSilent = false
    private(set) var remoteSource: CaptureAudioSource = .system

    private var micPeak: Float = 0
    private var remotePeak: Float = 0
    private var watchTask: Task<Void, Never>?
    private var monitoring = false
    var onMicDeclaredSilent: (@MainActor () -> Void)?

    /// Peak (0…1) below this after grace counts as silent. Tuned for quiet mics that still ASR well.
    private let silenceFloor: Float = 0.008
    private let decay: Float = 0.86

    func start(remoteSource: CaptureAudioSource) {
        stop()
        self.remoteSource = remoteSource
        micLevel = 0
        remoteLevel = 0
        micPeak = 0
        remotePeak = 0
        micSilent = false
        remoteSilent = false
        monitoring = true
        armMicSilenceWatch()
    }

    /// Re-arm silence detection after switching to a fallback mic.
    func resetMicProbe() {
        guard monitoring else { return }
        micLevel = 0
        micPeak = 0
        micSilent = false
        armMicSilenceWatch()
    }

    private func armMicSilenceWatch() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.monitoring else { return }
            let micDead = self.micPeak < self.silenceFloor
            self.micSilent = micDead
            self.remoteSilent = self.remotePeak < self.silenceFloor
            if micDead {
                self.onMicDeclaredSilent?()
            }
        }
    }

    func stop() {
        monitoring = false
        watchTask?.cancel()
        watchTask = nil
        micLevel = 0
        remoteLevel = 0
        micSilent = false
        remoteSilent = false
    }

    func dismissMicWarning() { micSilent = false }
    func dismissRemoteWarning() { remoteSilent = false }

    /// Treat successful speech as proof the mic is live (covers metering format edge cases).
    func noteMicSpeechActivity() {
        guard monitoring else { return }
        micPeak = max(micPeak, 0.35)
        micLevel = max(micLevel, 0.28)
        micSilent = false
    }

    nonisolated func ingestMic(_ sampleBuffer: CMSampleBuffer) {
        let level = AudioSignalMonitor.peakLevel(sampleBuffer)
        Task { @MainActor in
            self.apply(level: level, toMic: true)
        }
    }

    nonisolated func ingestRemote(_ sampleBuffer: CMSampleBuffer) {
        let level = AudioSignalMonitor.peakLevel(sampleBuffer)
        Task { @MainActor in
            self.apply(level: level, toMic: false)
        }
    }

    private func apply(level: Float, toMic: Bool) {
        guard monitoring else { return }
        if toMic {
            micPeak = max(micPeak, level)
            micLevel = max(level, micLevel * decay)
            if level >= silenceFloor { micSilent = false }
        } else {
            remotePeak = max(remotePeak, level)
            remoteLevel = max(level, remoteLevel * decay)
            if level >= silenceFloor { remoteSilent = false }
        }
    }

    /// Peak magnitude 0…1 from interleaved or non-interleaved PCM (SCK mic is often interleaved).
    nonisolated private static func peakLevel(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return 0 }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            // Fall back through AVAudioPCMBuffer when the sample has no contiguous block.
            return peakFromPCM(AudioPCM.buffer(from: sampleBuffer))
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr,
              let dataPointer,
              length > 0
        else {
            return peakFromPCM(AudioPCM.buffer(from: sampleBuffer))
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let is16 = (asbd.mBitsPerChannel == 16) && !isFloat
        let is32Float = (asbd.mBitsPerChannel == 32) && isFloat

        if is32Float {
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { return 0 }
            return dataPointer.withMemoryRebound(to: Float.self, capacity: count) { pointer in
                var maxValue: Float = 0
                vDSP_maxmgv(pointer, 1, &maxValue, vDSP_Length(count))
                return min(1, maxValue * 3.2)
            }
        }

        if is16 {
            let count = length / MemoryLayout<Int16>.size
            guard count > 0 else { return 0 }
            return dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { pointer in
                var maxValue: Float = 0
                var floats = [Float](repeating: 0, count: count)
                vDSP_vflt16(pointer, 1, &floats, 1, vDSP_Length(count))
                var scale: Float = 1.0 / Float(Int16.max)
                vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
                vDSP_maxmgv(floats, 1, &maxValue, vDSP_Length(count))
                return min(1, maxValue * 3.2)
            }
        }

        return peakFromPCM(AudioPCM.buffer(from: sampleBuffer))
    }

    nonisolated private static func peakFromPCM(_ pcm: AVAudioPCMBuffer?) -> Float {
        guard let pcm, pcm.frameLength > 0 else { return 0 }
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        var maxValue: Float = 0

        if let data = pcm.floatChannelData {
            for channel in 0..<channels {
                var channelMax: Float = 0
                vDSP_maxmgv(data[channel], 1, &channelMax, vDSP_Length(frames))
                maxValue = max(maxValue, channelMax)
            }
            return min(1, maxValue * 3.2)
        }

        if let data = pcm.int16ChannelData {
            for channel in 0..<channels {
                var floats = [Float](repeating: 0, count: frames)
                vDSP_vflt16(data[channel], 1, &floats, 1, vDSP_Length(frames))
                var scale: Float = 1.0 / Float(Int16.max)
                vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(frames))
                var channelMax: Float = 0
                vDSP_maxmgv(floats, 1, &channelMax, vDSP_Length(frames))
                maxValue = max(maxValue, channelMax)
            }
            return min(1, maxValue * 3.2)
        }

        // Interleaved buffer: read first AudioBuffer's bytes.
        let list = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard let first = list.first, let mData = first.mData, first.mDataByteSize > 0 else { return 0 }
        if pcm.format.commonFormat == .pcmFormatFloat32 {
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = mData.bindMemory(to: Float.self, capacity: count)
            vDSP_maxmgv(pointer, 1, &maxValue, vDSP_Length(count))
            return min(1, maxValue * 3.2)
        }
        if pcm.format.commonFormat == .pcmFormatInt16 {
            let count = Int(first.mDataByteSize) / MemoryLayout<Int16>.size
            let pointer = mData.bindMemory(to: Int16.self, capacity: count)
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt16(pointer, 1, &floats, 1, vDSP_Length(count))
            var scale: Float = 1.0 / Float(Int16.max)
            vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
            vDSP_maxmgv(floats, 1, &maxValue, vDSP_Length(count))
            return min(1, maxValue * 3.2)
        }
        return 0
    }
}
