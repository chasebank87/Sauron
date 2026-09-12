import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// Online speaker clustering for remote (system / meeting-app) audio only.
/// Local mic is never diarized (always "You").
final class SpeakerDiarizer: @unchecked Sendable {
    struct Turn: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var speakerKey: String
        var fingerprint: [Float]
    }

    /// Indices in the fingerprint vector.
    private static let bandCount = 16
    private static let pitchBinCount = 8
    private static let f0Index = 18 // after 16 bands + centroid + flatness
    private static let pitchHistStart = 19

    private let lock = NSLock()
    private let fingerprintQueue = DispatchQueue(label: "app.sauron.diarizer.fingerprint", qos: .utility)
    private var startedAt: Date?
    private var sampleRate: Double = 48_000
    private var silenceGap: TimeInterval = 0.65
    private var speechFloor: Float = 0.012
    private var clusterThreshold: Float = 0.88
    private var profileThreshold: Float = 0.90
    /// Reject merges when log-F0 differs by more than this (≈ major male/female gap).
    private var maxLogF0Delta: Float = 0.22

    private var inSpeech = false
    private var turnStart: TimeInterval = 0
    private var lastSpeechAt: TimeInterval = 0
    private var samples: [Float] = []
    private var clusters: [(key: String, centroid: [Float], count: Int)] = []
    private var turns: [Turn] = []
    private var nextCluster = 1
    private var profilePrints: [(key: String, vector: [Float])] = []
    private var elapsedFrames: Int = 0

    func start(profilePrints: [(key: String, vector: [Float])] = []) {
        lock.lock()
        defer { lock.unlock() }
        startedAt = .now
        self.profilePrints = profilePrints
        inSpeech = false
        turnStart = 0
        lastSpeechAt = 0
        samples = []
        clusters = []
        turns = []
        nextCluster = 1
        elapsedFrames = 0
        sampleRate = 48_000
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        closeTurnLocked(at: currentTimeLocked())
        startedAt = nil
    }

    func reset() {
        stop()
        start(profilePrints: profilePrints)
    }

    func updateProfiles(_ prints: [(key: String, vector: [Float])]) {
        lock.lock()
        defer { lock.unlock() }
        profilePrints = prints
    }

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = AudioPCM.buffer(from: sampleBuffer) else { return }
        ingest(pcm)
    }

    func ingest(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard startedAt != nil else { return }

        sampleRate = pcm.format.sampleRate
        let mono = Self.monoSamples(from: pcm)
        guard !mono.isEmpty else { return }

        let frameStart = Double(elapsedFrames) / sampleRate
        elapsedFrames += mono.count
        let rms = Self.rms(mono)
        let now = frameStart + Double(mono.count) / sampleRate

        if rms >= speechFloor {
            if !inSpeech {
                inSpeech = true
                turnStart = frameStart
                samples = []
            }
            samples.append(contentsOf: mono)
            lastSpeechAt = now
        } else if inSpeech, now - lastSpeechAt >= silenceGap {
            closeTurnLocked(at: lastSpeechAt)
        }
    }

    /// Best speaker key covering the majority of [start, end].
    func speakerKey(at start: TimeInterval, end: TimeInterval) -> String {
        lock.lock()
        defer { lock.unlock() }
        let span = max(0.05, end - start)
        if turns.isEmpty {
            if let last = clusters.last { return last.key }
            return SpeakerKey.cluster(1)
        }
        var scores: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = max(0, min(end, turn.end) - max(start, turn.start))
            guard overlap > 0 else { continue }
            scores[turn.speakerKey, default: 0] += overlap
        }
        if let winner = scores.max(by: { $0.value < $1.value }), winner.value > span * 0.15 {
            return winner.key
        }
        if inSpeech, let last = turns.last {
            return last.speakerKey
        }
        return turns.last?.speakerKey ?? SpeakerKey.cluster(1)
    }

    func fingerprint(forSpeakerKey key: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let matching = turns.filter { $0.speakerKey == key }.map(\.fingerprint)
        guard !matching.isEmpty else {
            return clusters.first(where: { $0.key == key })?.centroid
        }
        return Self.average(matching)
    }

    func allTurns() -> [Turn] {
        lock.lock()
        defer { lock.unlock() }
        return turns
    }

    // MARK: - Internals

    private func currentTimeLocked() -> TimeInterval {
        Double(elapsedFrames) / max(1, sampleRate)
    }

    private func closeTurnLocked(at end: TimeInterval) {
        guard inSpeech else { return }
        inSpeech = false
        let start = turnStart
        let duration = end - start
        let captured = samples
        let rate = sampleRate
        samples = []
        guard duration >= 0.25, captured.count > 400 else { return }

        fingerprintQueue.async { [weak self] in
            guard let self else { return }
            let slices = Self.segmentTurn(
                samples: captured,
                sampleRate: rate,
                turnStart: start,
                turnEnd: end
            )
            self.lock.lock()
            defer { self.lock.unlock() }
            for slice in slices {
                guard !slice.fingerprint.isEmpty else { continue }
                let key = self.assignKeyLocked(fingerprint: slice.fingerprint)
                self.turns.append(
                    Turn(start: slice.start, end: slice.end, speakerKey: key, fingerprint: slice.fingerprint)
                )
            }
        }
    }

    private func assignKeyLocked(fingerprint: [Float]) -> String {
        var bestProfile: (key: String, score: Float)?
        for print in profilePrints {
            guard Self.pitchCompatible(fingerprint, print.vector, maxLogF0Delta: maxLogF0Delta) else { continue }
            let score = Self.cosine(fingerprint, print.vector)
            if score >= profileThreshold, score > (bestProfile?.score ?? -1) {
                bestProfile = (print.key, score)
            }
        }
        if let bestProfile {
            updateClusterLocked(key: bestProfile.key, fingerprint: fingerprint)
            return bestProfile.key
        }

        var bestCluster: (key: String, score: Float, index: Int)?
        for (index, cluster) in clusters.enumerated() {
            guard Self.pitchCompatible(fingerprint, cluster.centroid, maxLogF0Delta: maxLogF0Delta) else { continue }
            let score = Self.cosine(fingerprint, cluster.centroid)
            if score >= clusterThreshold, score > (bestCluster?.score ?? -1) {
                bestCluster = (cluster.key, score, index)
            }
        }
        if let bestCluster {
            let old = clusters[bestCluster.index]
            if Self.shouldUpdateCentroid(old: old.centroid, incoming: fingerprint, maxLogF0Delta: maxLogF0Delta) {
                let merged = zip(old.centroid, fingerprint).map { ($0 * Float(old.count) + $1) / Float(old.count + 1) }
                clusters[bestCluster.index] = (old.key, merged, old.count + 1)
            }
            return bestCluster.key
        }

        let key = SpeakerKey.cluster(nextCluster)
        nextCluster += 1
        clusters.append((key, fingerprint, 1))
        return key
    }

    private func updateClusterLocked(key: String, fingerprint: [Float]) {
        if let index = clusters.firstIndex(where: { $0.key == key }) {
            let old = clusters[index]
            if Self.shouldUpdateCentroid(old: old.centroid, incoming: fingerprint, maxLogF0Delta: maxLogF0Delta) {
                let merged = zip(old.centroid, fingerprint).map { ($0 * Float(old.count) + $1) / Float(old.count + 1) }
                clusters[index] = (old.key, merged, old.count + 1)
            }
        } else {
            clusters.append((key, fingerprint, 1))
        }
    }

    // MARK: - Features

    private static func monoSamples(from pcm: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(pcm.frameLength)
        guard frames > 0 else { return [] }
        if let channels = pcm.floatChannelData {
            let channelCount = Int(pcm.format.channelCount)
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channels[0], count: frames))
            }
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channelCount {
                let src = channels[c]
                for i in 0..<frames {
                    mono[i] += src[i]
                }
            }
            let scale = 1 / Float(channelCount)
            vDSP_vsmul(mono, 1, [scale], &mono, 1, vDSP_Length(frames))
            return mono
        }
        if let channels = pcm.int16ChannelData {
            let channelCount = Int(pcm.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            let scale: Float = 1 / 32_768
            for c in 0..<channelCount {
                let src = channels[c]
                for i in 0..<frames {
                    mono[i] += Float(src[i]) * scale
                }
            }
            if channelCount > 1 {
                let inv = 1 / Float(channelCount)
                vDSP_vsmul(mono, 1, [inv], &mono, 1, vDSP_Length(frames))
            }
            return mono
        }
        return []
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquares: Float = 0
        vDSP_measqv(samples, 1, &meanSquares, vDSP_Length(samples.count))
        return sqrtf(meanSquares)
    }

    /// Spectral bands + centroid/flatness + normalized log-F0 + pitch histogram.
    static func fingerprint(samples: [Float], sampleRate: Double) -> [Float] {
        let n = 512
        guard samples.count >= n else { return [] }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let hop = n / 2
        var bandEnergy = [Float](repeating: 0, count: bandCount)
        var frames = 0
        var centroidAccum: Float = 0
        var flatnessAccum: Float = 0
        var f0Values: [Float] = []
        var pitchHist = [Float](repeating: 0, count: pitchBinCount)

        var index = 0
        while index + n <= samples.count {
            var frame = Array(samples[index..<(index + n)])
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))

            var magnitudes = [Float](repeating: 0, count: n / 2)
            for k in 0..<(n / 2) {
                var real: Float = 0
                var imag: Float = 0
                for i in 0..<n {
                    let angle = 2 * Float.pi * Float(k) * Float(i) / Float(n)
                    real += frame[i] * cosf(angle)
                    imag -= frame[i] * sinf(angle)
                }
                magnitudes[k] = sqrtf(real * real + imag * imag) + 1e-9
            }

            let nyquist = Float(sampleRate) / 2
            for b in 0..<bandCount {
                let lo = Int(Float(b) / Float(bandCount) * Float(n / 2))
                let hi = max(lo + 1, Int(Float(b + 1) / Float(bandCount) * Float(n / 2)))
                var sum: Float = 0
                for k in lo..<min(hi, magnitudes.count) {
                    sum += magnitudes[k]
                }
                bandEnergy[b] += logf(sum + 1e-6)
            }

            var weighted: Float = 0
            var total: Float = 0
            var logSum: Float = 0
            for (k, mag) in magnitudes.enumerated() {
                let freq = Float(k) / Float(n / 2) * nyquist
                weighted += freq * mag
                total += mag
                logSum += logf(mag)
            }
            if total > 0 {
                centroidAccum += weighted / total / nyquist
                let geo = expf(logSum / Float(magnitudes.count))
                let arith = total / Float(magnitudes.count)
                flatnessAccum += geo / (arith + 1e-9)
            }

            if let f0 = estimateF0(frame: Array(samples[index..<(index + n)]), sampleRate: sampleRate) {
                f0Values.append(f0)
                let bin = pitchBin(for: f0)
                pitchHist[bin] += 1
            }

            frames += 1
            index += hop
            if frames >= 24 { break }
        }

        guard frames > 0 else { return [] }
        let inv = 1 / Float(frames)
        for i in 0..<bandEnergy.count {
            bandEnergy[i] *= inv
        }
        var norm: Float = 0
        vDSP_svesq(bandEnergy, 1, &norm, vDSP_Length(bandEnergy.count))
        norm = sqrtf(norm) + 1e-6
        var vector = bandEnergy.map { $0 / norm }
        vector.append(centroidAccum * inv)
        vector.append(min(1, flatnessAccum * inv))

        let medianF0 = median(f0Values) ?? 0
        let logF0Norm: Float
        if medianF0 > 0 {
            // Normalize log-F0 from ~80–300 Hz into roughly 0...1
            logF0Norm = (logf(medianF0) - logf(80)) / (logf(300) - logf(80))
        } else {
            logF0Norm = 0.5
        }
        vector.append(min(1, max(0, logF0Norm)))

        let histSum = pitchHist.reduce(0, +) + 1e-6
        vector.append(contentsOf: pitchHist.map { $0 / histSum })
        return vector
    }

    /// Split long turns when pitch / spectral fingerprint jumps.
    static func segmentTurn(
        samples: [Float],
        sampleRate: Double,
        turnStart: TimeInterval,
        turnEnd: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval, fingerprint: [Float])] {
        let duration = turnEnd - turnStart
        let full = fingerprint(samples: samples, sampleRate: sampleRate)
        guard !full.isEmpty else { return [] }
        guard duration >= 1.6, samples.count > Int(sampleRate * 1.2) else {
            return [(turnStart, turnEnd, full)]
        }

        let windowSec = 0.5
        let windowSamples = max(512, Int(sampleRate * windowSec))
        let hopSamples = max(256, windowSamples / 2)
        var windows: [(start: TimeInterval, end: TimeInterval, fingerprint: [Float])] = []
        var offset = 0
        while offset + windowSamples <= samples.count {
            let slice = Array(samples[offset..<(offset + windowSamples)])
            let fp = fingerprint(samples: slice, sampleRate: sampleRate)
            if !fp.isEmpty {
                let start = turnStart + Double(offset) / sampleRate
                let end = turnStart + Double(offset + windowSamples) / sampleRate
                windows.append((start, min(end, turnEnd), fp))
            }
            offset += hopSamples
        }
        guard windows.count >= 2 else { return [(turnStart, turnEnd, full)] }

        var segments: [(start: TimeInterval, end: TimeInterval, fingerprint: [Float])] = []
        var segStart = windows[0].start
        var segPrints: [[Float]] = [windows[0].fingerprint]
        var lastEnd = windows[0].end

        for i in 1..<windows.count {
            let prev = windows[i - 1].fingerprint
            let cur = windows[i].fingerprint
            let jump = !pitchCompatible(prev, cur, maxLogF0Delta: 0.18)
                || cosine(prev, cur) < 0.78
            if jump, let avg = average(segPrints).nilIfEmpty {
                segments.append((segStart, lastEnd, avg))
                segStart = windows[i].start
                segPrints = [cur]
            } else {
                segPrints.append(cur)
            }
            lastEnd = windows[i].end
        }
        if let avg = average(segPrints).nilIfEmpty {
            segments.append((segStart, turnEnd, avg))
        }
        return segments.isEmpty ? [(turnStart, turnEnd, full)] : segments
    }

    static func pitchCompatible(_ a: [Float], _ b: [Float], maxLogF0Delta: Float) -> Bool {
        guard a.count > f0Index, b.count > f0Index else { return true }
        let logA = a[f0Index]
        let logB = b[f0Index]
        // Both unknown / mid → allow
        if abs(logA - 0.5) < 0.05, abs(logB - 0.5) < 0.05 { return true }
        return abs(logA - logB) <= maxLogF0Delta
    }

    static func shouldUpdateCentroid(old: [Float], incoming: [Float], maxLogF0Delta: Float) -> Bool {
        pitchCompatible(old, incoming, maxLogF0Delta: maxLogF0Delta)
    }

    private static func estimateF0(frame: [Float], sampleRate: Double) -> Float? {
        // Autocorrelation pitch estimate in 80–300 Hz.
        let minLag = max(1, Int(sampleRate / 300))
        let maxLag = min(frame.count - 1, Int(sampleRate / 80))
        guard maxLag > minLag + 2 else { return nil }

        var bestLag = 0
        var bestCorr: Float = 0
        var energy: Float = 0
        vDSP_svesq(frame, 1, &energy, vDSP_Length(frame.count))
        guard energy > 1e-6 else { return nil }

        for lag in minLag...maxLag {
            var corr: Float = 0
            let count = frame.count - lag
            for i in 0..<count {
                corr += frame[i] * frame[i + lag]
            }
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }
        guard bestLag > 0, bestCorr / energy > 0.3 else { return nil }
        return Float(sampleRate / Double(bestLag))
    }

    private static func pitchBin(for f0: Float) -> Int {
        let clamped = min(300, max(80, f0))
        let t = (clamped - 80) / (300 - 80)
        return min(pitchBinCount - 1, max(0, Int(t * Float(pitchBinCount))))
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return -1 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrtf(na) * sqrtf(nb)
        guard denom > 1e-8 else { return -1 }
        return dot / denom
    }

    static func average(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        var count = 0
        for vector in vectors where vector.count == first.count {
            for i in 0..<acc.count {
                acc[i] += vector[i]
            }
            count += 1
        }
        guard count > 0 else { return [] }
        let inv = 1 / Float(count)
        return acc.map { $0 * inv }
    }
}

private extension Array where Element == Float {
    var nilIfEmpty: [Float]? { isEmpty ? nil : self }
}
