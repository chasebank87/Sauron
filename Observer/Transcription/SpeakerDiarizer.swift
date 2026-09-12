import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// Online speaker clustering for remote (system / meeting-app) audio.
final class SpeakerDiarizer: @unchecked Sendable {
    struct Turn: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var speakerKey: String
        var fingerprint: [Float]
    }

    private let lock = NSLock()
    private let fingerprintQueue = DispatchQueue(label: "app.observer.diarizer.fingerprint", qos: .utility)
    private var startedAt: Date?
    private var sampleRate: Double = 48_000
    private var silenceGap: TimeInterval = 0.65
    private var speechFloor: Float = 0.012
    private var clusterThreshold: Float = 0.82
    private var profileThreshold: Float = 0.88

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
            let fingerprint = Self.fingerprint(samples: captured, sampleRate: rate)
            guard !fingerprint.isEmpty else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            let key = self.assignKeyLocked(fingerprint: fingerprint)
            self.turns.append(Turn(start: start, end: end, speakerKey: key, fingerprint: fingerprint))
        }
    }

    private func assignKeyLocked(fingerprint: [Float]) -> String {
        var bestProfile: (key: String, score: Float)?
        for print in profilePrints {
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
            let score = Self.cosine(fingerprint, cluster.centroid)
            if score >= clusterThreshold, score > (bestCluster?.score ?? -1) {
                bestCluster = (cluster.key, score, index)
            }
        }
        if let bestCluster {
            let old = clusters[bestCluster.index]
            let merged = zip(old.centroid, fingerprint).map { ($0 * Float(old.count) + $1) / Float(old.count + 1) }
            clusters[bestCluster.index] = (old.key, merged, old.count + 1)
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
            let merged = zip(old.centroid, fingerprint).map { ($0 * Float(old.count) + $1) / Float(old.count + 1) }
            clusters[index] = (old.key, merged, old.count + 1)
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

    /// Compact log-band energy fingerprint (16 bands) + spectral centroid / rolloff cues.
    private static func fingerprint(samples: [Float], sampleRate: Double) -> [Float] {
        let n = 512
        guard samples.count >= n else { return [] }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let hop = n / 2
        var bandEnergy = [Float](repeating: 0, count: 16)
        var frames = 0
        var centroidAccum: Float = 0
        var flatnessAccum: Float = 0

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
            for b in 0..<16 {
                let lo = Int(Float(b) / 16 * Float(n / 2))
                let hi = max(lo + 1, Int(Float(b + 1) / 16 * Float(n / 2)))
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

            frames += 1
            index += hop
            if frames >= 24 { break }
        }

        guard frames > 0 else { return [] }
        let inv = 1 / Float(frames)
        for i in 0..<bandEnergy.count {
            bandEnergy[i] *= inv
        }
        // L2 normalize bands
        var norm: Float = 0
        vDSP_svesq(bandEnergy, 1, &norm, vDSP_Length(bandEnergy.count))
        norm = sqrtf(norm) + 1e-6
        var vector = bandEnergy.map { $0 / norm }
        vector.append(centroidAccum * inv)
        vector.append(min(1, flatnessAccum * inv))
        return vector
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return -1 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = sqrtf(na) * sqrtf(nb)
        guard denom > 1e-8 else { return -1 }
        return dot / denom
    }

    private static func average(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            for i in 0..<acc.count {
                acc[i] += vector[i]
            }
        }
        let inv = 1 / Float(vectors.count)
        return acc.map { $0 * inv }
    }
}
