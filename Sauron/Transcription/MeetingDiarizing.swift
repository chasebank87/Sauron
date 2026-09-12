import CoreMedia
import Foundation

/// Contract for remote-channel speaker labeling during a meeting.
/// Local mic is never diarized (always `SpeakerKey.selfKey`).
protocol MeetingDiarizing: AnyObject {
    func start(profilePrints: [(key: String, vector: [Float])])
    func stop()
    func ingest(_ sampleBuffer: CMSampleBuffer)
    func speakerKey(at start: TimeInterval, end: TimeInterval) -> String
    func fingerprint(forSpeakerKey key: String) -> [Float]?
}

/// Pure helpers shared by classic / neural backends and tests.
enum DiarizationTimelineMapper {
    struct Turn: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var speakerKey: String
    }

    /// Map Sortformer’s 0-based slot index → `cluster:1…4`.
    static func clusterKey(sortformerIndex: Int) -> String {
        SpeakerKey.cluster(sortformerIndex + 1)
    }

    /// Best speaker key covering the majority of `[start, end]`.
    static func speakerKey(
        turns: [Turn],
        at start: TimeInterval,
        end: TimeInterval,
        fallback: String = SpeakerKey.cluster(1)
    ) -> String {
        let span = max(0.05, end - start)
        guard !turns.isEmpty else { return fallback }
        var scores: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = max(0, min(end, turn.end) - max(start, turn.start))
            guard overlap > 0 else { continue }
            scores[turn.speakerKey, default: 0] += overlap
        }
        if let winner = scores.max(by: { $0.value < $1.value }), winner.value > span * 0.15 {
            return winner.key
        }
        return turns.last?.speakerKey ?? fallback
    }
}

/// Wraps the existing pitch-gated classical diarizer.
final class ClassicMeetingDiarizer: MeetingDiarizing, @unchecked Sendable {
    private let inner = SpeakerDiarizer()
    private let queue = DispatchQueue(label: "app.sauron.diarizer.classic", qos: .utility)

    func start(profilePrints: [(key: String, vector: [Float])]) {
        queue.sync {
            inner.start(profilePrints: profilePrints)
        }
    }

    func stop() {
        queue.sync {
            inner.stop()
        }
    }

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        // Retain PCM immediately; process off the ScreenCaptureKit callback queue.
        guard let pcm = AudioPCM.buffer(from: sampleBuffer) else { return }
        queue.async { [weak self] in
            self?.inner.ingest(pcm)
        }
    }

    func speakerKey(at start: TimeInterval, end: TimeInterval) -> String {
        queue.sync {
            inner.speakerKey(at: start, end: end)
        }
    }

    func fingerprint(forSpeakerKey key: String) -> [Float]? {
        queue.sync {
            inner.fingerprint(forSpeakerKey: key)
        }
    }

    func exportTurns() -> [DiarizationTimelineMapper.Turn] {
        queue.sync {
            inner.allTurns().map {
                DiarizationTimelineMapper.Turn(start: $0.start, end: $0.end, speakerKey: $0.speakerKey)
            }
        }
    }
}

/// Routes remote audio to neural Sortformer when ready, otherwise classical F0 clustering.
final class DiarizationRouter: MeetingDiarizing, @unchecked Sendable {
    private let classic = ClassicMeetingDiarizer()
    private let lock = NSLock()
    private var neural: NeuralMeetingDiarizer?
    private var preferNeural = true
    private var profilePrints: [(key: String, vector: [Float])] = []
    private var isRunning = false

    var isUsingNeural: Bool {
        lock.lock()
        defer { lock.unlock() }
        return preferNeural && (neural?.isReady == true)
    }

    func setPreferNeural(_ enabled: Bool) {
        lock.lock()
        preferNeural = enabled
        let running = isRunning
        let prints = profilePrints
        let active = activeLocked()
        lock.unlock()
        if running {
            // Switch backends mid-meeting: restart the newly selected path.
            classic.stop()
            neural?.stop()
            active.start(profilePrints: prints)
        }
    }

    func attachNeural(_ diarizer: NeuralMeetingDiarizer?) {
        lock.lock()
        neural = diarizer
        let running = isRunning
        let prefer = preferNeural
        let prints = profilePrints
        lock.unlock()
        if running, prefer, diarizer?.isReady == true {
            classic.stop()
            diarizer?.start(profilePrints: prints)
        }
    }

    func start(profilePrints: [(key: String, vector: [Float])]) {
        lock.lock()
        self.profilePrints = profilePrints
        isRunning = true
        let active = activeLocked()
        lock.unlock()
        classic.stop()
        neural?.stop()
        active.start(profilePrints: profilePrints)
    }

    func stop() {
        lock.lock()
        isRunning = false
        let active = activeLocked()
        lock.unlock()
        active.stop()
    }

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let active = activeLocked()
        lock.unlock()
        active.ingest(sampleBuffer)
    }

    func speakerKey(at start: TimeInterval, end: TimeInterval) -> String {
        lock.lock()
        let active = activeLocked()
        lock.unlock()
        return active.speakerKey(at: start, end: end)
    }

    func fingerprint(forSpeakerKey key: String) -> [Float]? {
        lock.lock()
        let active = activeLocked()
        lock.unlock()
        return active.fingerprint(forSpeakerKey: key)
    }

    /// Turns from the active backend for post-meeting ASR speaker tagging.
    func timelineTurns() -> [DiarizationTimelineMapper.Turn] {
        lock.lock()
        let neuralBackend = neural
        let usingNeural = preferNeural && (neural?.isReady == true)
        lock.unlock()
        if usingNeural {
            return neuralBackend?.exportTurns() ?? []
        }
        return classic.exportTurns()
    }

    private func activeLocked() -> MeetingDiarizing {
        if preferNeural, let neural, neural.isReady {
            return neural
        }
        return classic
    }
}
