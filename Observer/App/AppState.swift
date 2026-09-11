import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    let modelContainer: ModelContainer
    var settings: SettingsStore
    var status: AppStatus = .idle
    var candidate: MeetingCandidate?
    var promptCapture: CaptureMedia
    var promptTranscript: Bool
    var promptMeetingAppAudio: Bool
    var liveSegments: [LiveSegment] = []
    var recordingStartedAt: Date?
    var currentMeeting: Meeting?
    var selectedMeeting: Meeting?
    var streamPreview: String = ""
    var errorMessage: String?
    var wantsOnboarding = false
    var reportToken: UUID?
    var lastError: String?
    var isSummarizing = false
    var postMeetingPhase: PostMeetingPhase = .idle
    let audioMonitor = AudioSignalMonitor()

    @ObservationIgnored let detector = MeetingDetector()
    @ObservationIgnored let capture = CaptureEngine()
    @ObservationIgnored let transcription = TranscriptionEngine()
    @ObservationIgnored let promptPanel = GlassPanelController()
    @ObservationIgnored let transcriptPanel = GlassPanelController()
    @ObservationIgnored let errorPanel = GlassPanelController()
    @ObservationIgnored let onboardingPanel = GlassPanelController()
    @ObservationIgnored private var detectorWatch: Task<Void, Never>?
    @ObservationIgnored private var micPriorityIndex = 0
    private(set) var activeMicDisplayName = "System Default"

    var modelContext: ModelContext { modelContainer.mainContext }

    var promptAudioSource: CaptureAudioSource {
        promptMeetingAppAudio ? .meetingApp : .system
    }

    var recentMeetings: [Meeting] {
        MeetingStore.recent(context: modelContext)
    }

    var elapsed: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    var menuSymbol: String {
        switch status {
        case .idle, .detecting: "eye"
        case .prompt: "eye.circle"
        case .recording: "record.circle"
        case .processing: "sparkles"
        }
    }

    private init() {
        modelContainer = SharedModel.container
        let store = SettingsStore()
        settings = store
        promptCapture = store.defaultCapture
        promptTranscript = store.defaultTranscript
        promptMeetingAppAudio = store.meetingAppAudioOnly
        let transcriptionEngine = transcription
        let monitor = audioMonitor
        transcriptionEngine.onSegment = { segment in
            Task { @MainActor in
                AppState.shared.upsert(segment)
            }
        }
        capture.onSystemAudio = { buffer in
            monitor.ingestRemote(buffer)
            transcriptionEngine.feedSystem(buffer)
        }
        capture.onMicAudio = { buffer in
            monitor.ingestMic(buffer)
            transcriptionEngine.feedMic(buffer)
        }
        capture.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.fail(error)
            }
        }
        capture.onCaptureInterrupted = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .recording else { return }
                await self.finishRecording()
            }
        }
        audioMonitor.onMicDeclaredSilent = { [weak self] in
            Task { @MainActor in
                await self?.advanceMicrophoneFallback()
            }
        }
    }

    func start() {
        if !settings.hasCompletedOnboarding {
            showOnboarding()
            return
        }
        beginDetectionIfNeeded()
    }

    func showOnboarding() {
        wantsOnboarding = true
        guard !onboardingPanel.isVisible else { return }
        onboardingPanel.present(
            PermissionsOnboarding()
                .environment(self),
            size: GlassChrome.onboardingSize,
            placement: .center,
            activates: true
        )
    }

    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        wantsOnboarding = false
        onboardingPanel.close()
        beginDetectionIfNeeded()
    }

    func beginDetectionIfNeeded() {
        guard settings.watchForMeetings else {
            detector.stop()
            status = .idle
            return
        }
        detector.start()
        if status == .idle { status = .detecting }
        if detectorWatch == nil {
            detectorWatch = Task { await watchDetector() }
        }
    }

    func simulateMeeting() {
        guard status != .recording, status != .processing else { return }
        candidate = .simulated()
        applyDefaultPrompt()
        status = .prompt
        showPrompt()
    }

    func persistPromptDefaults() {
        settings.defaultCapture = promptCapture
        settings.defaultTranscript = promptTranscript
        settings.meetingAppAudioOnly = promptMeetingAppAudio
    }

    private func applyDefaultPrompt() {
        promptCapture = settings.defaultCapture
        promptTranscript = settings.defaultTranscript
        promptMeetingAppAudio = settings.meetingAppAudioOnly
    }

    var promptModes: Set<RecordMode> {
        promptCapture.modes(transcript: promptTranscript)
    }

    func startRecording() {
        Task { await runRecording() }
    }

    func snoozePrompt() {
        detector.snooze(candidate)
        candidate = nil
        promptPanel.close()
        if status == .prompt {
            status = settings.watchForMeetings ? .detecting : .idle
        }
    }

    func muteAppToday() {
        detector.muteApp(candidate)
        candidate = nil
        promptPanel.close()
        if status == .prompt {
            status = settings.watchForMeetings ? .detecting : .idle
        }
    }

    func stopRecording() {
        Task { await finishRecording() }
    }

    func openReport(_ meeting: Meeting) {
        selectedMeeting = meeting
        reportToken = UUID()
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissError() {
        errorMessage = nil
        errorPanel.close()
    }

    func makeClient() throws -> (LLMClient, String) {
        let kind = settings.providerKind
        let urlString: String
        switch kind {
        case .ollama: urlString = settings.ollamaURL
        case .lmStudio: urlString = settings.lmStudioURL
        case .openRouter: urlString = settings.openRouterURL
        }
        guard let url = URL(string: urlString) else {
            throw ObserverError.providerUnreachable(kind.displayName)
        }
        if kind.requiresAPIKey, (KeychainStore.openRouterAPIKey ?? "").isEmpty {
            throw ObserverError.missingAPIKey
        }
        let client = LLMClient(
            kind: kind,
            baseURL: url,
            apiKey: KeychainStore.openRouterAPIKey
        )
        return (client, settings.modelID)
    }

    private func watchDetector() async {
        var lastKey: String?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            if status == .recording, detector.recordedMeetingEnded {
                detector.clearRecordingWatch()
                await finishRecording()
                lastKey = nil
                continue
            }
            guard status == .idle || status == .detecting || status == .prompt else { continue }
            if let expired = detector.consumeExpiredPromptSession(), status == .prompt, expired == lastKey {
                candidate = nil
                promptPanel.close()
                status = settings.watchForMeetings ? .detecting : .idle
                lastKey = nil
                continue
            }
            if let detected = detector.candidate {
                if detected.sessionKey != lastKey, status != .prompt {
                    candidate = detected
                    applyDefaultPrompt()
                    status = .prompt
                    showPrompt()
                    lastKey = detected.sessionKey
                }
            }
        }
    }

    private func showPrompt() {
        promptPanel.present(
            RecordPromptView()
                .environment(self),
            size: GlassChrome.promptSize,
            placement: .topCenter,
            activates: true
        )
    }

    private func showTranscript() {
        // Ambient mesh lives behind content; skip NSGlassEffectView so color stays vivid.
        transcriptPanel.present(
            TranscriptPanelView()
                .environment(self),
            size: GlassChrome.transcriptSize,
            placement: .trailing,
            usesPaneChrome: true
        )
    }

    private func showErrorPanel() {
        errorPanel.present(
            ErrorPanelView()
                .environment(self),
            size: GlassChrome.errorSize,
            placement: .topCenter
        )
    }

    private func runRecording() async {
        guard let candidate else { return }
        persistPromptDefaults()
        promptPanel.close()
        detector.watchRecording(candidate)
        detector.snooze(candidate)

        let meeting = MeetingStore.create(from: candidate, modes: promptModes, context: modelContext)
        currentMeeting = meeting
        liveSegments = []
        streamPreview = ""
        recordingStartedAt = .now
        status = .recording
        let priority = AudioDeviceCatalog.resolvedPriority(savedIDs: settings.micPriorityIDs)
        micPriorityIndex = 0
        activeMicDisplayName = priority.first?.name ?? "System Default"
        audioMonitor.start(remoteSource: promptAudioSource)

        do {
            let modes = promptModes
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            if !micOK { throw ObserverError.microphoneDenied }
            if modes.contains(.transcript) {
                try await TranscriptionEngine.ensureModel()
                try await transcription.start()
            }
            try await capture.start(
                candidate: candidate,
                modes: modes,
                audioSource: promptAudioSource,
                microphoneDeviceID: priority.first?.captureDeviceID,
                folder: MediaStore.folder(for: meeting.id)
            )
            meeting.videoPath = capture.videoPath
            meeting.micAudioPath = capture.micPath
            meeting.systemAudioPath = capture.systemPath
            try? modelContext.save()
            showTranscript()
        } catch {
            audioMonitor.stop()
            await capture.stop()
            _ = await transcription.stop()
            fail(error)
            meeting.status = .failed
            try? modelContext.save()
        }
    }

    private func finishRecording() async {
        guard status == .recording, let meeting = currentMeeting else { return }
        status = .processing
        postMeetingPhase = .savingCapture
        isSummarizing = true
        defer {
            postMeetingPhase = .idle
            isSummarizing = false
        }
        detector.clearRecordingWatch()
        audioMonitor.stop()

        // Freeze transcript into the report immediately, then show the window.
        var segments = liveSegments
        meeting.endedAt = .now
        meeting.status = .processing
        MeetingStore.persist(liveSegments: segments, into: meeting, context: modelContext)
        try? modelContext.save()
        transcriptPanel.close()
        openReport(meeting)

        await capture.stop()
        if meeting.recordTranscript {
            let finals = await transcription.stop()
            if !finals.isEmpty {
                segments = merge(live: segments, finals: finals)
                liveSegments = segments
                MeetingStore.persist(liveSegments: segments, into: meeting, context: modelContext)
            }
        }
        meeting.videoPath = capture.videoPath
        meeting.micAudioPath = capture.micPath
        meeting.systemAudioPath = capture.systemPath
        try? modelContext.save()

        if meeting.recordAudio || meeting.recordTranscript {
            postMeetingPhase = .mixingAudio
            let folder = MediaStore.folder(for: meeting.id)
            let output = AudioMixComposer.mixedURL(in: folder)
            let micURL = capture.micPath.map { URL(fileURLWithPath: $0) }
            let systemURL = capture.systemPath.map { URL(fileURLWithPath: $0) }
            do {
                if let mixed = try await AudioMixComposer.mix(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputURL: output
                ) {
                    meeting.mixedAudioPath = mixed.path
                    try? modelContext.save()
                }
            } catch {
                lastError = "Mixed audio unavailable: \(error.localizedDescription)"
            }
        }

        postMeetingPhase = .summarizing
        await summarize(meeting)
        currentMeeting = nil
        recordingStartedAt = nil
        candidate = nil
        status = settings.watchForMeetings ? .detecting : .idle
    }

    private func summarize(_ meeting: Meeting) async {
        meeting.status = .processing
        try? modelContext.save()
        let transcript = meeting.plainTranscript
        guard meeting.recordTranscript else {
            meeting.status = .ready
            try? modelContext.save()
            return
        }
        do {
            streamPreview = ""
            let (client, configuredModel) = try makeClient()
            let models = (try? await client.listModels()) ?? []
            let model = configuredModel.isEmpty ? (models.first?.id ?? OpenRouterProvider.suggestedModel) : configuredModel
            let messages = Summarizer.messages(
                transcript: transcript,
                meetingTitle: meeting.title,
                appName: meeting.appName
            )
            var raw = ""
            for try await chunk in client.streamChat(model: model, messages: messages) {
                raw += chunk
                streamPreview = raw
            }
            let summary = Summarizer.parse(raw)
            if let data = try? JSONEncoder().encode(summary) {
                meeting.summaryJSON = String(data: data, encoding: .utf8)
            }
            if !summary.title.isEmpty {
                meeting.title = summary.title
            }
            meeting.status = .ready
        } catch {
            meeting.status = transcript.isEmpty ? .ready : .failed
            lastError = error.localizedDescription
            streamPreview = "Transcript saved. Connect a provider in Settings to summarize.\n\n\(error.localizedDescription)"
        }
        try? modelContext.save()
    }

    private func advanceMicrophoneFallback() async {
        guard status == .recording else { return }
        let priority = AudioDeviceCatalog.resolvedPriority(savedIDs: settings.micPriorityIDs)
        let nextIndex = micPriorityIndex + 1
        guard nextIndex < priority.count else { return }
        let next = priority[nextIndex]
        do {
            try await capture.switchMicrophone(to: next.captureDeviceID)
            micPriorityIndex = nextIndex
            activeMicDisplayName = next.name
            audioMonitor.resetMicProbe()
            audioMonitor.dismissMicWarning()
        } catch {
            lastError = "Could not switch microphone to \(next.name): \(error.localizedDescription)"
        }
    }

    private func upsert(_ segment: LiveSegment) {
        if segment.speaker == .you, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            audioMonitor.noteMicSpeechActivity()
        }
        if let index = liveSegments.firstIndex(where: { $0.id == segment.id }) {
            liveSegments[index] = segment
        } else {
            liveSegments.append(segment)
            liveSegments.sort { $0.start < $1.start }
        }
    }

    private func merge(live: [LiveSegment], finals: [LiveSegment]) -> [LiveSegment] {
        var byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        for item in finals {
            byID[item.id] = item
        }
        return byID.values.sorted { $0.start < $1.start }
    }

    private func fail(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showErrorPanel()
        detector.clearRecordingWatch()
        audioMonitor.stop()
        postMeetingPhase = .idle
        isSummarizing = false
        if status == .recording || status == .processing {
            status = settings.watchForMeetings ? .detecting : .idle
            transcriptPanel.close()
        }
    }
}
