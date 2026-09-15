import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// SpeexDSP MDF acoustic echo canceller for meeting recording.
///
/// Far-end reference is preferably the Sauron Audio virtual loopback (meeting-app
/// output hijack); otherwise ScreenCaptureKit / process-tap capture.
/// Near-end is the microphone. VoiceProcessingIO is not used here — without owning
/// playback as a duplex unit, Apple’s canceller has no reference and would only duck other apps.
final class AcousticEchoCanceller: @unchecked Sendable {
    static let processSampleRate = 16_000
    static let frameSize = 160
    static let tailSize = 3_200

    private let lock = NSLock()
    private var engine: OpaquePointer?
    private var farChunks: [(time: Double, samples: [Int16])] = []
    private var nearPending: [Int16] = []
    private var nearTimeCursor: Double?
    private var cancelledPending: [Int16] = []

    init() {
        engine = SauronAECEngineCreate(
            Int32(Self.processSampleRate),
            Int32(Self.frameSize),
            Int32(Self.tailSize)
        )
    }

    deinit {
        lock.lock()
        let leftover = engine
        engine = nil
        lock.unlock()
        SauronAECEngineDestroy(leftover)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let engine {
            SauronAECEngineReset(engine)
        }
        farChunks.removeAll(keepingCapacity: true)
        nearPending.removeAll(keepingCapacity: true)
        cancelledPending.removeAll(keepingCapacity: true)
        nearTimeCursor = nil
    }

    func ingestFarEnd(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = AudioPCM.buffer(from: sampleBuffer) else { return }
        let mono = AudioPCM.mixdown(pcm)
        let rate = pcm.format.sampleRate
        let resampled = AudioPCM.resample(mono, from: rate, to: Double(Self.processSampleRate))
        ingestFarEnd16k(AudioPCM.int16(from: resampled), time: Self.alignmentTime(of: sampleBuffer))
    }

    func processNearEnd(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard engine != nil, let pcm = AudioPCM.buffer(from: sampleBuffer) else {
            return sampleBuffer
        }
        let frames = Int(pcm.frameLength)
        guard frames > 0 else { return sampleBuffer }

        let mono = AudioPCM.mixdown(pcm)
        let rate = pcm.format.sampleRate
        let resampled = AudioPCM.resample(mono, from: rate, to: Double(Self.processSampleRate))
        let cancelled16 = processNearEnd16k(
            AudioPCM.int16(from: resampled),
            time: Self.alignmentTime(of: sampleBuffer)
        )
        let cancelledFloat = AudioPCM.resample(
            AudioPCM.floats(from: cancelled16),
            from: Double(Self.processSampleRate),
            to: rate,
            count: frames
        )
        return AudioPCM.replacing(sampleBuffer: sampleBuffer, withMono: cancelledFloat) ?? sampleBuffer
    }

    /// 16 kHz mono far-end (system / meeting-app playback).
    func ingestFarEnd16k(_ samples: [Int16], time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty, time.isFinite else { return }
        farChunks.append((time, samples))
        let cutoff = time - 2.0
        farChunks.removeAll { chunk in
            let end = chunk.time + Double(chunk.samples.count) / Double(Self.processSampleRate)
            return end < cutoff
        }
    }

    /// 16 kHz mono mic. Returns the same number of samples (≈10 ms pipeline delay at start).
    func processNearEnd16k(_ samples: [Int16], time: Double) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        guard let engine, !samples.isEmpty, time.isFinite else { return samples }

        if nearPending.isEmpty || nearTimeCursor == nil {
            nearTimeCursor = time
        } else if let cursor = nearTimeCursor, abs(time - cursor) > 0.08 {
            nearTimeCursor = time
            nearPending.removeAll(keepingCapacity: true)
        }

        nearPending.append(contentsOf: samples)

        while nearPending.count >= Self.frameSize {
            let frame = Array(nearPending.prefix(Self.frameSize))
            nearPending.removeFirst(Self.frameSize)
            let frameTime = nearTimeCursor ?? time
            nearTimeCursor = frameTime + Double(Self.frameSize) / Double(Self.processSampleRate)
            let far = farSamplesLocked(at: frameTime, count: Self.frameSize)
            var out = [Int16](repeating: 0, count: Self.frameSize)
            out.withUnsafeMutableBufferPointer { outPointer in
                frame.withUnsafeBufferPointer { nearPointer in
                    far.withUnsafeBufferPointer { farPointer in
                        SauronAECEngineCancel(
                            engine,
                            nearPointer.baseAddress,
                            farPointer.baseAddress,
                            outPointer.baseAddress
                        )
                    }
                }
            }
            if Self.rms(out) > Self.rms(frame) * 2.5 {
                cancelledPending.append(contentsOf: frame)
            } else if Self.isSpeakerOnlyEcho(near: frame, far: far, cancelled: out) {
                // Live "You" (and the mic file) must not keep speaker bleed Apple Speech would caption.
                cancelledPending.append(contentsOf: [Int16](repeating: 0, count: Self.frameSize))
            } else {
                cancelledPending.append(contentsOf: out)
            }
        }

        let needed = samples.count
        if cancelledPending.count >= needed {
            let chunk = Array(cancelledPending.prefix(needed))
            cancelledPending.removeFirst(needed)
            return chunk
        }
        let have = cancelledPending
        cancelledPending.removeAll(keepingCapacity: true)
        let pad = needed - have.count
        if pad <= 0 { return have }
        return Array(samples.prefix(pad)) + have
    }

    private func farSamplesLocked(at start: Double, count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)
        let rate = Double(Self.processSampleRate)
        let end = start + Double(count) / rate
        for chunk in farChunks {
            let chunkEnd = chunk.time + Double(chunk.samples.count) / rate
            if chunkEnd <= start || chunk.time >= end { continue }
            let overlapStart = max(start, chunk.time)
            let overlapEnd = min(end, chunkEnd)
            let dst0 = Int(((overlapStart - start) * rate).rounded())
            let src0 = Int(((overlapStart - chunk.time) * rate).rounded())
            let n = Int(((overlapEnd - overlapStart) * rate).rounded())
            guard n > 0 else { continue }
            for i in 0..<n {
                let dst = dst0 + i
                let src = src0 + i
                guard dst >= 0, dst < count, src >= 0, src < chunk.samples.count else { continue }
                out[dst] = chunk.samples[src]
            }
        }
        return out
    }

    static func alignmentTime(of sampleBuffer: CMSampleBuffer) -> Double {
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            let seconds = pts.seconds
            if seconds.isFinite, abs(seconds - host) < 8 {
                return seconds
            }
        }
        return host
    }

    private static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var acc = 0.0
        for sample in samples {
            let value = Double(sample)
            acc += value * value
        }
        return sqrt(acc / Double(samples.count))
    }

    /// True when this frame is meeting audio on the speakers, not the local talker.
    /// Used so live "You" dictation does not caption playback from the laptop speakers.
    /// Conservative on double-talk: keep residual when it still looks like local speech.
    /// System/"Others" transcription is unchanged (separate lane).
    static func isSpeakerOnlyEcho(near: [Int16], far: [Int16], cancelled: [Int16]) -> Bool {
        let farRMS = rms(far)
        guard farRMS > 400 else { return false }

        let nearRMS = rms(near)
        let outRMS = rms(cancelled)
        let farCorr = abs(normalizedCorrelation(near, far))
        let residualCorr = abs(normalizedCorrelation(cancelled, far))

        // Double-talk: residual still strong and not locked to far-end — keep You.
        if outRMS > 1_800, outRMS > farRMS * 0.28, residualCorr < 0.42 {
            return false
        }

        // Clear cancel: residual much quieter than both near and far.
        if outRMS < nearRMS * 0.28, outRMS < farRMS * 0.45 {
            return true
        }

        // Near still tracks far and residual stays quiet — speaker bleed only.
        if farCorr > 0.5, residualCorr > 0.38, outRMS < farRMS * 0.35 {
            return true
        }
        return false
    }

    static func normalizedCorrelation(_ left: [Int16], _ right: [Int16]) -> Double {
        let count = min(left.count, right.count)
        guard count > 0 else { return 0 }
        var dot = 0.0
        var leftEnergy = 0.0
        var rightEnergy = 0.0
        for index in 0..<count {
            let a = Double(left[index])
            let b = Double(right[index])
            dot += a * b
            leftEnergy += a * a
            rightEnergy += b * b
        }
        let denom = sqrt(leftEnergy * rightEnergy)
        guard denom > 1 else { return 0 }
        return dot / denom
    }
}
