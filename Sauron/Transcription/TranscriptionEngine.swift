import AVFAudio
import CoreMedia
import Foundation
import Speech

final class TranscriptionEngine: @unchecked Sendable {
    var onSegment: (@Sendable (LiveSegment) -> Void)?

    /// Mic lane gets priority so “You” captions stay snappy under dual-stream load.
    private let micQueue = DispatchQueue(label: "app.sauron.transcription.mic", qos: .userInitiated)
    private let systemQueue = DispatchQueue(label: "app.sauron.transcription.system", qos: .utility)
    private var session: Session?
    private var startedAt: Date = .now
    private var ownedReservedLocale: Locale?

    func start(locale: Locale = .current) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SauronError.speechUnavailable
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SauronError.speechUnavailable
        }

        if session != nil {
            _ = await stop()
        }

        startedAt = .now
        let createdReservation = try await AssetInventory.reserve(locale: resolved)
        ownedReservedLocale = createdReservation ? resolved : nil

        do {
            let you = try await makeLane(locale: resolved, speaker: .you)
            let others = try await makeLane(locale: resolved, speaker: .others)
            you.startConsuming { [weak self] segment in
                self?.onSegment?(segment)
            }
            others.startConsuming { [weak self] segment in
                self?.onSegment?(segment)
            }
            try await you.analyzer.start(inputSequence: you.stream)
            try await others.analyzer.start(inputSequence: others.stream)
            session = Session(you: you, others: others)
        } catch {
            await releaseOwnedReservation()
            throw error
        }
    }

    func feedMic(_ sampleBuffer: CMSampleBuffer) {
        // Copy PCM while the SCK buffer is still valid (callback lifetime).
        guard let pcm = AudioPCM.buffer(from: sampleBuffer) else { return }
        micQueue.async { [weak self] in
            self?.session?.you.feed(pcm)
        }
    }

    func feedSystem(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = AudioPCM.buffer(from: sampleBuffer) else { return }
        systemQueue.async { [weak self] in
            self?.session?.others.feed(pcm)
        }
    }

    func stop() async -> [LiveSegment] {
        let current = session
        session = nil
        await current?.you.finish()
        await current?.others.finish()
        await releaseOwnedReservation()
        let you = current?.you.committed ?? []
        let others = current?.others.committed ?? []
        return (you + others).sorted { $0.start < $1.start }
    }

    static func ensureModel(locale: Locale = .current) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SauronError.speechUnavailable
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SauronError.speechUnavailable
        }
        let transcriber = makeTranscriber(locale: resolved)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
    }

    private func makeLane(locale: Locale, speaker: Speaker) async throws -> Lane {
        let transcriber = Self.makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SauronError.speechUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        return Lane(
            speaker: speaker,
            transcriber: transcriber,
            analyzer: analyzer,
            format: format,
            startedAt: startedAt
        )
    }

    private func releaseOwnedReservation() async {
        guard let locale = ownedReservedLocale else { return }
        ownedReservedLocale = nil
        _ = await AssetInventory.release(reservedLocale: locale)
    }
}

private final class Lane: @unchecked Sendable {
    let speaker: Speaker
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AnalyzerBufferConverter
    private var volatileID: UUID?
    private(set) var committed: [LiveSegment] = []
    private let startedAt: Date
    private var consumer: Task<Void, Never>?
    private var handler: (@Sendable (LiveSegment) -> Void)?
    private var nextRelativeTime: CMTime = .zero
    /// Maps this lane’s continuous analyzer timeline onto meeting wall-clock.
    private var timelineAnchorWall: TimeInterval = 0
    private var hasAnchor = false

    init(
        speaker: Speaker,
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        format: AVAudioFormat,
        startedAt: Date
    ) {
        self.speaker = speaker
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        self.startedAt = startedAt
        self.converter = AnalyzerBufferConverter(outputFormat: format)
        // Never drop audio — bufferingNewest caused skipped words when the analyzer lagged.
        let pair = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startConsuming(handler: @escaping @Sendable (LiveSegment) -> Void) {
        self.handler = handler
        consumer = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    guard !Task.isCancelled else { return }
                    self.publish(result)
                }
            } catch is CancellationError {
                // Stopped intentionally.
            } catch {
                // Stream finished or cancelled.
            }
        }
    }

    func feed(_ source: AVAudioPCMBuffer) {
        guard let converted = try? converter.convert(source), converted.frameLength > 0 else { return }
        let wall = Date().timeIntervalSince(startedAt)
        if !hasAnchor {
            timelineAnchorWall = wall
            hasAnchor = true
        } else {
            // After mute / queue stalls, slide the display anchor so this lane
            // realigns with meeting time without breaking analyzer continuity.
            let expectedWall = timelineAnchorWall + nextRelativeTime.seconds
            if wall - expectedWall > 0.45 {
                timelineAnchorWall = wall - nextRelativeTime.seconds
            }
        }

        let duration = CMTime(
            value: CMTimeValue(converted.frameLength),
            timescale: CMTimeScale(converted.format.sampleRate)
        )
        let start = nextRelativeTime
        nextRelativeTime = start + duration
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    func finish() async {
        continuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            consumer?.cancel()
        }
        await consumer?.value
        consumer = nil
    }

    private func publish(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let analyzerStart = result.range.start.seconds
        let analyzerEnd = result.range.end.seconds
        let wallNow = Date().timeIntervalSince(startedAt)
        let start: TimeInterval
        let end: TimeInterval
        if analyzerStart.isFinite, analyzerEnd.isFinite {
            start = max(0, timelineAnchorWall + analyzerStart)
            end = max(start + 0.05, timelineAnchorWall + analyzerEnd)
        } else {
            start = wallNow
            end = wallNow
        }

        let id: UUID
        if result.isFinal {
            id = volatileID ?? UUID()
            volatileID = nil
        } else if let existing = volatileID {
            id = existing
        } else {
            id = UUID()
            volatileID = id
        }

        let segment = LiveSegment(
            id: id,
            speakerKey: speaker.speakerKey,
            text: text,
            start: start,
            end: end,
            isFinal: result.isFinal,
            updatedAt: wallNow
        )
        if result.isFinal {
            committed.removeAll { $0.id == id }
            committed.append(segment)
        }
        handler?(segment)
    }
}

private struct Session {
    let you: Lane
    let others: Lane
}

private final class AnalyzerBufferConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        if converter == nil
            || converter?.inputFormat.isEqual(inputBuffer.format) == false
            || converter?.outputFormat.isEqual(outputFormat) == false {
            converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw SauronError.transcriptionFailed("Could not convert audio for speech.")
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SauronError.transcriptionFailed("Could not allocate speech audio buffer.")
        }

        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error || conversionError != nil {
            throw SauronError.transcriptionFailed(
                conversionError?.localizedDescription ?? "Audio conversion failed."
            )
        }
        return output
    }
}
