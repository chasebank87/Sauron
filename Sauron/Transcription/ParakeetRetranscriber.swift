import FluidAudio
import Foundation

/// Post-meeting Parakeet retranscription that upgrades the live Apple Speech transcript.
enum ParakeetRetranscriber {
    struct LaneResult: Sendable {
        var segments: [LiveSegment]
        var confidence: Float
        var textLength: Int
    }

    /// Build timed utterance segments from an ASR result (word timings + pause splits).
    static func segments(
        from result: ASRResult,
        speakerKey: String,
        pauseGap: TimeInterval = 0.65
    ) -> [LiveSegment] {
        let timings = result.tokenTimings ?? []
        let words = buildWordTimings(from: timings)
        if words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                LiveSegment(
                    id: UUID(),
                    speakerKey: speakerKey,
                    text: text,
                    start: 0,
                    end: max(0.5, result.duration),
                    isFinal: true
                )
            ]
        }

        var chunks: [(start: TimeInterval, end: TimeInterval, words: [String])] = []
        var currentWords: [String] = []
        var chunkStart = words[0].startTime
        var chunkEnd = words[0].endTime
        var lastEnd = words[0].endTime

        for word in words {
            if word.startTime - lastEnd >= pauseGap, !currentWords.isEmpty {
                chunks.append((chunkStart, chunkEnd, currentWords))
                currentWords = []
                chunkStart = word.startTime
            }
            if currentWords.isEmpty {
                chunkStart = word.startTime
            }
            currentWords.append(word.word)
            chunkEnd = max(chunkEnd, word.endTime)
            lastEnd = word.endTime
        }
        if !currentWords.isEmpty {
            chunks.append((chunkStart, chunkEnd, currentWords))
        }

        return chunks.compactMap { chunk in
            let text = chunk.words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveSegment(
                id: UUID(),
                speakerKey: speakerKey,
                text: text,
                start: chunk.start,
                end: max(chunk.start + 0.05, chunk.end),
                isFinal: true
            )
        }
    }

    /// Tag remote (non-self) segments using a diarization turn timeline.
    static func tagRemote(
        segments: [LiveSegment],
        turns: [DiarizationTimelineMapper.Turn]
    ) -> [LiveSegment] {
        segments.map { segment in
            var copy = segment
            if SpeakerKey.isSelf(segment.speakerKey) {
                copy.speakerKey = SpeakerKey.selfKey
            } else {
                copy.speakerKey = DiarizationTimelineMapper.speakerKey(
                    turns: turns,
                    at: segment.start,
                    end: segment.end
                )
            }
            return copy
        }
    }

    /// Merge mic (You) + remote lanes; prefer upgraded transcript when long enough.
    static func mergeLanes(
        mic: [LiveSegment],
        remote: [LiveSegment],
        existing: [LiveSegment],
        micConfidence: Float,
        remoteConfidence: Float
    ) -> [LiveSegment]? {
        let upgraded = (mic + remote).sorted { $0.start < $1.start }
        let upgradedChars = upgraded.reduce(0) { $0 + $1.text.count }
        let existingChars = existing.reduce(0) { $0 + $1.text.count }
        guard upgradedChars >= max(24, Int(Double(existingChars) * 0.35)) else { return nil }
        let meanConfidence = (micConfidence + remoteConfidence) / 2
        if meanConfidence < 0.15, upgradedChars < existingChars { return nil }
        return upgraded
    }

    /// Transcribe a single audio file with Parakeet v2 when models are loaded.
    static func transcribeFile(
        url: URL,
        speakerKey: String,
        models: AsrModels
    ) async throws -> LaneResult {
        let manager = AsrManager(config: .default, models: models)
        try await manager.loadModels(models)
        var decoderState = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        let segs = segments(from: result, speakerKey: speakerKey)
        return LaneResult(
            segments: segs,
            confidence: result.confidence,
            textLength: result.text.count
        )
    }

    /// Enhance after capture using saved mic/system files + live diarization turns.
    static func enhance(
        micURL: URL?,
        systemURL: URL?,
        turns: [DiarizationTimelineMapper.Turn],
        existing: [LiveSegment],
        models: AsrModels
    ) async -> [LiveSegment]? {
        var micSegments: [LiveSegment] = []
        var remoteSegments: [LiveSegment] = []
        var micConfidence: Float = 1
        var remoteConfidence: Float = 1

        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            do {
                let lane = try await transcribeFile(
                    url: micURL,
                    speakerKey: SpeakerKey.selfKey,
                    models: models
                )
                micSegments = lane.segments
                micConfidence = lane.confidence
            } catch {
                // Keep going with remote-only upgrade if mic fails.
            }
        }

        if let systemURL, FileManager.default.fileExists(atPath: systemURL.path) {
            do {
                let lane = try await transcribeFile(
                    url: systemURL,
                    speakerKey: SpeakerKey.cluster(1),
                    models: models
                )
                remoteSegments = tagRemote(segments: lane.segments, turns: turns)
                remoteConfidence = lane.confidence
            } catch {
                // Soft-fail: caller keeps live transcript.
            }
        }

        guard !micSegments.isEmpty || !remoteSegments.isEmpty else { return nil }
        return mergeLanes(
            mic: micSegments,
            remote: remoteSegments,
            existing: existing,
            micConfidence: micConfidence,
            remoteConfidence: remoteConfidence
        )
    }
}
