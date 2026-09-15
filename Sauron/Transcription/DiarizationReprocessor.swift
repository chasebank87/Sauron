import AVFoundation
import Foundation

/// Re-runs diarization against an already-saved system-audio file, for meetings whose
/// live diarizer session no longer exists (reprocessing an old recording rather than
/// tagging speakers during capture).
enum DiarizationReprocessor {
    /// Streams `url` in fixed-size chunks through `diarizer` and returns the resulting
    /// speaker turns. `diarizer` must already have Sortformer models attached — pass
    /// `FluidAudioModelStore.shared.neuralDiarizer`, gated on `diarizationStatus.isReady`.
    static func turns(
        fromSystemAudio url: URL,
        diarizer: NeuralMeetingDiarizer,
        chunkSeconds: Double = 1.0
    ) async -> [DiarizationTimelineMapper.Turn] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(max(1, format.sampleRate * chunkSeconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return [] }

        diarizer.start(profilePrints: [])
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            let mono = AudioPCM.mixdown(buffer)
            if !mono.isEmpty {
                diarizer.ingestSamples(mono, sourceSampleRate: format.sampleRate)
            }
            await Task.yield()
        }
        diarizer.stop()
        return diarizer.exportTurns()
    }
}
