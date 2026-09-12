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

    /// Either source can fully drive the wave; keep levels close to true volume.
    var combinedLevel: Float {
        displayLevel(includingMic: true)
    }

    /// Wave / chip level — optionally ignore mic when muted.
    func displayLevel(includingMic: Bool) -> Float {
        let peak = includingMic ? max(micLevel, remoteLevel) : remoteLevel
        guard peak > 0 else { return 0 }
        // Mild quiet-end lift only; mid/loud stay nearly linear with volume.
        return min(1, pow(peak, 0.78))
    }

    var anySilent: Bool { micSilent || remoteSilent }

    private var micPeak: Float = 0
    private var remotePeak: Float = 0
    private var watchTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var monitoring = false
    var onMicDeclaredSilent: (@MainActor () -> Void)?

    /// Peak (0…1) below this after grace counts as silent.
    private let silenceFloor: Float = 0.02
    /// Fast attack / moderate release so the wave tracks speaking volume.
    private let riseBlend: Float = 0.78
    private let fallBlend: Float = 0.42

    /// Lock-protected pending levels written from the real-time capture queues.
    nonisolated private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pendingMic: Float = 0
    nonisolated(unsafe) private static var pendingRemote: Float = 0

    func start(remoteSource: CaptureAudioSource) {
        stop()
        self.remoteSource = remoteSource
        micLevel = 0
        remoteLevel = 0
        micPeak = 0
        remotePeak = 0
        micSilent = false
        remoteSilent = false
        Self.pendingLock.lock()
        Self.pendingMic = 0
        Self.pendingRemote = 0
        Self.pendingLock.unlock()
        monitoring = true
        armMicSilenceWatch()
        startPump()
    }

    /// Re-arm silence detection after switching to a fallback mic.
    func resetMicProbe() {
        guard monitoring else { return }
        micLevel = 0
        micPeak = 0
        micSilent = false
        Self.pendingLock.lock()
        Self.pendingMic = 0
        Self.pendingLock.unlock()
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

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.monitoring {
                self.drainPending()
                try? await Task.sleep(for: .milliseconds(16)) // ~60 Hz UI cadence
            }
        }
    }

    private func drainPending() {
        Self.pendingLock.lock()
        let mic = Self.pendingMic
        let remote = Self.pendingRemote
        // Decay pending peaks quickly so each pump reflects recent loudness.
        Self.pendingMic *= 0.78
        Self.pendingRemote *= 0.78
        Self.pendingLock.unlock()

        apply(level: mic, toMic: true)
        apply(level: remote, toMic: false)
    }

    func stop() {
        monitoring = false
        watchTask?.cancel()
        watchTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        micLevel = 0
        remoteLevel = 0
        micSilent = false
        remoteSilent = false
        Self.pendingLock.lock()
        Self.pendingMic = 0
        Self.pendingRemote = 0
        Self.pendingLock.unlock()
    }

    func dismissMicWarning() { micSilent = false }
    func dismissRemoteWarning() { remoteSilent = false }

    /// Treat successful speech as proof the mic is live (covers metering format edge cases).
    func noteMicSpeechActivity() {
        guard monitoring else { return }
        micPeak = max(micPeak, 0.45)
        micLevel = max(micLevel, 0.4)
        micSilent = false
    }

    nonisolated func ingestMic(_ sampleBuffer: CMSampleBuffer) {
        // Mic is usually hotter than SCK system audio.
        let level = Self.meterLevel(sampleBuffer, gain: 6.5)
        Self.pendingLock.lock()
        Self.pendingMic = max(Self.pendingMic, level)
        Self.pendingLock.unlock()
    }

    nonisolated func ingestRemote(_ sampleBuffer: CMSampleBuffer) {
        // ScreenCaptureKit system/app audio often sits much quieter than the mic.
        let level = Self.meterLevel(sampleBuffer, gain: 14.0)
        Self.pendingLock.lock()
        Self.pendingRemote = max(Self.pendingRemote, level)
        Self.pendingLock.unlock()
    }

    private func apply(level: Float, toMic: Bool) {
        guard monitoring else { return }
        if toMic {
            micPeak = max(micPeak, level)
            let blend = level > micLevel ? riseBlend : fallBlend
            micLevel += (level - micLevel) * blend
            if level >= silenceFloor { micSilent = false }
        } else {
            remotePeak = max(remotePeak, level)
            let blend = level > remoteLevel ? riseBlend : fallBlend
            remoteLevel += (level - remoteLevel) * blend
            if level >= silenceFloor { remoteSilent = false }
        }
    }

    /// RMS → dBFS → normalized 0…1, then boosted by `gain` for UI presence.
    nonisolated private static func meterLevel(_ sampleBuffer: CMSampleBuffer, gain: Float) -> Float {
        let rms = rmsLevel(sampleBuffer)
        guard rms > 1e-8 else { return 0 }
        let db = 20 * log10(Double(rms))
        // Map a wide speaking / app-audio range into 0…1.
        let floorDB = -55.0
        let ceilDB = -8.0
        var normalized = (db - floorDB) / (ceilDB - floorDB)
        normalized = min(max(normalized, 0), 1)
        // Keep metering close to loudness (was 0.6 — too compressive).
        normalized = pow(normalized, 0.88)
        // Extra linear gain so soft remote streams still move the line.
        return min(1, Float(normalized) * (gain / 6.0))
    }

    nonisolated private static func rmsLevel(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            return rmsFromPCM(AudioPCM.buffer(from: sampleBuffer))
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return rmsFromPCM(AudioPCM.buffer(from: sampleBuffer))
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
            return rmsFromPCM(AudioPCM.buffer(from: sampleBuffer))
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let is16 = (asbd.mBitsPerChannel == 16) && !isFloat
        let is32Float = (asbd.mBitsPerChannel == 32) && isFloat

        if is32Float {
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { return 0 }
            return dataPointer.withMemoryRebound(to: Float.self, capacity: count) { pointer in
                var meanSquare: Float = 0
                vDSP_measqv(pointer, 1, &meanSquare, vDSP_Length(count))
                return sqrt(meanSquare)
            }
        }

        if is16 {
            let count = length / MemoryLayout<Int16>.size
            guard count > 0 else { return 0 }
            return dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { pointer in
                var floats = [Float](repeating: 0, count: count)
                vDSP_vflt16(pointer, 1, &floats, 1, vDSP_Length(count))
                var scale: Float = 1.0 / Float(Int16.max)
                vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
                var meanSquare: Float = 0
                vDSP_measqv(floats, 1, &meanSquare, vDSP_Length(count))
                return sqrt(meanSquare)
            }
        }

        return rmsFromPCM(AudioPCM.buffer(from: sampleBuffer))
    }

    nonisolated private static func rmsFromPCM(_ pcm: AVAudioPCMBuffer?) -> Float {
        guard let pcm, pcm.frameLength > 0 else { return 0 }
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        var best: Float = 0

        if let data = pcm.floatChannelData {
            for channel in 0..<channels {
                var meanSquare: Float = 0
                vDSP_measqv(data[channel], 1, &meanSquare, vDSP_Length(frames))
                best = max(best, sqrt(meanSquare))
            }
            return best
        }

        if let data = pcm.int16ChannelData {
            for channel in 0..<channels {
                var floats = [Float](repeating: 0, count: frames)
                vDSP_vflt16(data[channel], 1, &floats, 1, vDSP_Length(frames))
                var scale: Float = 1.0 / Float(Int16.max)
                vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(frames))
                var meanSquare: Float = 0
                vDSP_measqv(floats, 1, &meanSquare, vDSP_Length(frames))
                best = max(best, sqrt(meanSquare))
            }
            return best
        }

        let list = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard let first = list.first, let mData = first.mData, first.mDataByteSize > 0 else { return 0 }
        if pcm.format.commonFormat == .pcmFormatFloat32 {
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = mData.bindMemory(to: Float.self, capacity: count)
            var meanSquare: Float = 0
            vDSP_measqv(pointer, 1, &meanSquare, vDSP_Length(count))
            return sqrt(meanSquare)
        }
        if pcm.format.commonFormat == .pcmFormatInt16 {
            let count = Int(first.mDataByteSize) / MemoryLayout<Int16>.size
            let pointer = mData.bindMemory(to: Int16.self, capacity: count)
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt16(pointer, 1, &floats, 1, vDSP_Length(count))
            var scale: Float = 1.0 / Float(Int16.max)
            vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
            var meanSquare: Float = 0
            vDSP_measqv(floats, 1, &meanSquare, vDSP_Length(count))
            return sqrt(meanSquare)
        }
        return 0
    }
}
