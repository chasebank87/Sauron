import Accelerate
import AVFoundation
import CoreMedia
import CoreML
import FluidAudio
import Foundation

/// Streaming Sortformer diarization for remote/system audio on the Neural Engine.
final class NeuralMeetingDiarizer: MeetingDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.sauron.diarizer.neural", qos: .utility)
    private let config: SortformerConfig
    private var sortformer: SortformerDiarizer?
    private var turns: [DiarizationTimelineMapper.Turn] = []
    private var started = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sortformer?.isAvailable == true
    }

    init(config: SortformerConfig = .default) {
        self.config = config
    }

    func attach(models: SortformerModels) {
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        lock.lock()
        sortformer = diarizer
        turns = []
        lock.unlock()
    }

    func clearModels() {
        lock.lock()
        sortformer?.cleanup()
        sortformer = nil
        turns = []
        started = false
        lock.unlock()
    }

    func start(profilePrints: [(key: String, vector: [Float])]) {
        _ = profilePrints // Sortformer has no persistent voiceprints; profiles assigned in Report.
        queue.sync {
            lock.lock()
            started = true
            turns = []
            sortformer?.reset()
            lock.unlock()
        }
    }

    func stop() {
        queue.sync {
            lock.lock()
            defer { lock.unlock() }
            guard started else { return }
            started = false
            do {
                _ = try sortformer?.finalizeSession()
            } catch {
                // Soft-fail: keep whatever turns we already have.
            }
            refreshTurnsLocked()
        }
    }

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        // Copy while the SCK buffer is valid, then process off the capture queue.
        guard let pcm = AudioPCM.buffer(from: sampleBuffer) else { return }
        let mono = Self.monoSamples(from: pcm)
        guard !mono.isEmpty else { return }
        let rate = pcm.format.sampleRate
        queue.async { [weak self] in
            self?.processChunk(mono, sourceSampleRate: rate)
        }
    }

    /// Synchronous counterpart to `ingest(_:)` for feeding audio read from an already-saved
    /// file (reprocessing an old meeting) instead of live ScreenCaptureKit buffers. The
    /// caller controls read/feed ordering, so this blocks until the chunk is processed.
    func ingestSamples(_ samples: [Float], sourceSampleRate: Double) {
        guard !samples.isEmpty else { return }
        queue.sync {
            processChunk(samples, sourceSampleRate: sourceSampleRate)
        }
    }

    private func processChunk(_ samples: [Float], sourceSampleRate: Double) {
        lock.lock()
        let active = started
        let diarizer = sortformer
        lock.unlock()
        guard active, let diarizer else { return }
        do {
            _ = try diarizer.process(samples: samples, sourceSampleRate: sourceSampleRate)
            lock.lock()
            refreshTurnsLocked()
            lock.unlock()
        } catch {
            // Drop this chunk; caller continues with the rest of the stream/file.
        }
    }

    func speakerKey(at start: TimeInterval, end: TimeInterval) -> String {
        lock.lock()
        defer { lock.unlock() }
        return DiarizationTimelineMapper.speakerKey(turns: turns, at: start, end: end)
    }

    func fingerprint(forSpeakerKey key: String) -> [Float]? {
        _ = key
        return nil
    }

    /// Finalized + tentative turns for post-meeting ASR speaker tagging.
    func exportTurns() -> [DiarizationTimelineMapper.Turn] {
        lock.lock()
        defer { lock.unlock() }
        return turns
    }

    private func refreshTurnsLocked() {
        guard let timeline = sortformer?.timeline else {
            turns = []
            return
        }
        var next: [DiarizationTimelineMapper.Turn] = []
        for speaker in timeline.speakers.values {
            for segment in speaker.finalizedSegments {
                next.append(
                    DiarizationTimelineMapper.Turn(
                        start: TimeInterval(segment.startTime),
                        end: TimeInterval(segment.endTime),
                        speakerKey: DiarizationTimelineMapper.clusterKey(sortformerIndex: segment.speakerIndex)
                    )
                )
            }
            for segment in speaker.tentativeSegments {
                next.append(
                    DiarizationTimelineMapper.Turn(
                        start: TimeInterval(segment.startTime),
                        end: TimeInterval(segment.endTime),
                        speakerKey: DiarizationTimelineMapper.clusterKey(sortformerIndex: segment.speakerIndex)
                    )
                )
            }
        }
        turns = next.sorted { $0.start < $1.start }
    }

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
        return []
    }
}
