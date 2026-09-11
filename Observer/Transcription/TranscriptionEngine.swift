import AVFAudio
import CoreMedia
import Foundation
import Speech

final class TranscriptionEngine: @unchecked Sendable {
    var onSegment: (@Sendable (LiveSegment) -> Void)?

    private let queue = DispatchQueue(label: "app.observer.transcription")
    private var session: Session?
    private var startedAt: Date = .now
    private var ownedReservedLocale: Locale?

    func start(locale: Locale = .current) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw ObserverError.speechUnavailable
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ObserverError.speechUnavailable
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
        feed(sampleBuffer, speaker: .you)
    }

    func feedSystem(_ sampleBuffer: CMSampleBuffer) {
        feed(sampleBuffer, speaker: .others)
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
            throw ObserverError.speechUnavailable
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ObserverError.speechUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: resolved,
            preset: .timeIndexedProgressiveTranscription
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private func feed(_ sampleBuffer: CMSampleBuffer, speaker: Speaker) {
        queue.async { [weak self] in
            guard let self, let session else { return }
            let lane = speaker == .you ? session.you : session.others
            lane.feed(sampleBuffer)
        }
    }

    private func makeLane(locale: Locale, speaker: Speaker) async throws -> Lane {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ObserverError.speechUnavailable
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

    func feed(_ sampleBuffer: CMSampleBuffer) {
        guard let source = AudioPCM.buffer(from: sampleBuffer) else { return }
        guard let converted = try? converter.convert(source), converted.frameLength > 0 else { return }
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

        let start = result.range.start.seconds
        let end = result.range.end.seconds
        let fallback = Date().timeIntervalSince(startedAt)
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
            speaker: speaker,
            text: text,
            start: start.isFinite ? start : fallback,
            end: end.isFinite ? end : fallback,
            isFinal: result.isFinal
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
            throw ObserverError.transcriptionFailed("Could not convert audio for speech.")
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ObserverError.transcriptionFailed("Could not allocate speech audio buffer.")
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
            throw ObserverError.transcriptionFailed(
                conversionError?.localizedDescription ?? "Audio conversion failed."
            )
        }
        return output
    }
}
