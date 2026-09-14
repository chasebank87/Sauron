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
    var promptVideoTarget: CaptureVideoTarget = .auto
    var captureTargetOptions: [CaptureTargetOption] = []
    var liveSegments: [LiveSegment] = []
    /// Segment that most recently changed — transcript panel scrolls to this for live interleave.
    var liveTranscriptFocusID: UUID?
    var recordingStartedAt: Date?
    var currentMeeting: Meeting?
    var selectedMeeting: Meeting?
    var streamPreview: String = ""
    var errorMessage: String?
    var wantsOnboarding = false
    var reportToken: UUID?
    var dashboardToken: UUID?
    var dashboardSelectedTab: DashboardTab = .home
    var lastError: String?
    var isSummarizing = false
    var postMeetingPhase: PostMeetingPhase = .idle
    /// Bumped after capture files are fully finalized so players reload finished media.
    var mediaReadyToken = UUID()
    /// True while the user has toggled the mic mute button during the current recording.
    var isMicMuted = false
    let audioMonitor = AudioSignalMonitor()
    var assistCards: [LiveAssistCard] = []

    @ObservationIgnored let detector = MeetingDetector()
    @ObservationIgnored let capture = CaptureEngine()
    @ObservationIgnored let transcription = TranscriptionEngine()
    @ObservationIgnored let diarizer = DiarizationRouter()
    @ObservationIgnored let fluidModels = FluidAudioModelStore.shared
    @ObservationIgnored let liveAssistant = LiveAssistantEngine()
    @ObservationIgnored let promptPanel = GlassPanelController()
    @ObservationIgnored let transcriptPanel = GlassPanelController()
    @ObservationIgnored let assistPanel = GlassPanelController()
    @ObservationIgnored let errorPanel = GlassPanelController()
    @ObservationIgnored let onboardingPanel = GlassPanelController()
    let memoryMCPServer = MemoryMCPServer()
    @ObservationIgnored private var detectorWatch: Task<Void, Never>?
    @ObservationIgnored private var hotkeyMonitor: GlobalHotkeyMonitor?
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
        SpeakerProfileStore.shared.attach(context: modelContainer.mainContext)
        fluidModels.attach(router: diarizer)
        diarizer.setPreferNeural(store.neuralDiarizationEnabled)
        if store.neuralDiarizationEnabled || store.enhanceTranscriptEnabled {
            fluidModels.prepareIfNeeded(enabled: true)
        }
        let transcriptionEngine = transcription
        let monitor = audioMonitor
        let remoteDiarizer = diarizer
        liveAssistant.onCardsChanged = { [weak self] cards in
            self?.assistCards = cards
        }
        transcriptionEngine.onSegment = { segment in
            Task { @MainActor in
                AppState.shared.upsert(segment)
            }
        }
        capture.onSystemAudio = { buffer in
            monitor.ingestRemote(buffer)
            remoteDiarizer.ingest(buffer)
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
                // SCK often stops the *video* stream when Zoom/Teams recreates a
                // window mid-call. That is not a meeting end — only the detector
                // (or the Stop button) should finish the recording.
                _ = self
            }
        }
        capture.onMicMuteChanged = { [weak self] muted in
            Task { @MainActor in
                self?.isMicMuted = muted
            }
        }
        audioMonitor.onMicDeclaredSilent = { [weak self] in
            Task { @MainActor in
                await self?.advanceMicrophoneFallback()
            }
        }
        detector.subscribedCalendarIDsProvider = { [weak self] in
            self?.settings.effectiveSubscribedCalendarIDs
        }
        memoryMCPServer.attach(appState: self)
    }

    func start() {
        // Memory MCP is independent of meeting detection / onboarding UI.
        syncMemoryMCPServer()
        if !settings.hasCompletedOnboarding {
            showOnboarding()
            return
        }
        beginDetectionIfNeeded()
        installDashboardHotkey()
    }

    func syncMemoryMCPServer() {
        memoryMCPServer.syncWithSettings()
    }

    func installDashboardHotkey() {
        hotkeyMonitor?.stop()
        let monitor = GlobalHotkeyMonitor(
            keyCode: settings.dashboardShortcutKeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: settings.dashboardShortcutModifiers)
        ) { [weak self] in
            Task { @MainActor in
                self?.openDashboard()
            }
        }
        monitor.start()
        hotkeyMonitor = monitor
    }

    func openDashboard(tab: DashboardTab? = nil) {
        if let tab {
            dashboardSelectedTab = tab
        }
        dashboardToken = UUID()
        NSApp.activate(ignoringOtherApps: true)
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
        promptVideoTarget = .auto
        captureTargetOptions = [
            CaptureTargetOption(
                id: CaptureVideoTarget.auto.id,
                title: "Auto (recommended)",
                subtitle: "Best meeting window at start",
                systemImage: "sparkles.rectangle.stack",
                target: .auto
            )
        ]
        Task { await refreshCaptureTargetOptions() }
    }

    func refreshCaptureTargetOptions() async {
        let options = await CaptureTargetCatalog.options(for: candidate)
        captureTargetOptions = options
        if !options.contains(where: { $0.target == promptVideoTarget }) {
            promptVideoTarget = .auto
        }
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

    func toggleMicMute() {
        guard status == .recording else { return }
        capture.toggleMicMute()
        isMicMuted = capture.isMicMuted
    }

    func stopRecording() {
        Task { await finishRecording() }
    }

    func openReport(_ meeting: Meeting) {
        selectedMeeting = meeting
        reportToken = UUID()
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func deleteMeetings(_ meetings: [Meeting]) -> Int {
        let ids = Set(meetings.map(\.id))
        let count = MeetingStore.delete(meetings, context: modelContext)
        if let selected = selectedMeeting, ids.contains(selected.id) {
            selectedMeeting = nil
        }
        return count
    }

    func meetingDocuments(for meeting: Meeting) -> [MeetingDocument] {
        MeetingDocumentStore.list(for: meeting.id)
    }

    @discardableResult
    func attachDocuments(to meeting: Meeting, urls: [URL]) async throws -> [MeetingDocument] {
        let attached = try MeetingDocumentStore.attach(urls: urls, to: meeting.id)
        await MeetingMemoryIndexer.index(meeting: meeting, appState: self)
        return attached
    }

    func removeDocument(_ document: MeetingDocument, from meeting: Meeting) async throws {
        try MeetingDocumentStore.remove(id: document.id, from: meeting.id)
        await MeetingMemoryIndexer.index(meeting: meeting, appState: self)
    }

    func saveUserNotes(_ notes: String, for meeting: Meeting) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.userNotes = trimmed.isEmpty ? nil : notes
        try? modelContext.save()
        Task {
            await MeetingMemoryIndexer.index(meeting: meeting, appState: self)
        }
    }

    func resummarize(_ meeting: Meeting) {
        Task {
            isSummarizing = true
            postMeetingPhase = .summarizing
            defer {
                postMeetingPhase = .idle
                isSummarizing = false
            }
            await summarize(meeting)
        }
    }

    func assignSpeaker(
        from sourceKey: String,
        to profile: SpeakerProfile,
        in meeting: Meeting
    ) {
        let target = profile.speakerKey
        MeetingStore.remapSpeaker(
            from: sourceKey,
            to: target,
            in: meeting,
            context: modelContext
        )
        if let vector = diarizer.fingerprint(forSpeakerKey: sourceKey)
            ?? diarizer.fingerprint(forSpeakerKey: target) {
            SpeakerProfileStore.shared.updateVoiceprint(profile, vector: vector)
        }
        // Keep liveSegments in sync if this is the current meeting
        for index in liveSegments.indices where liveSegments[index].speakerKey == SpeakerKey.normalize(sourceKey) {
            liveSegments[index].speakerKey = target
        }
    }

    func createAndAssignSpeaker(name: String, from sourceKey: String, in meeting: Meeting) {
        let profile = SpeakerProfileStore.shared.addPerson(name: name)
        assignSpeaker(from: sourceKey, to: profile, in: meeting)
    }

    func dismissError() {
        errorMessage = nil
        errorPanel.close()
    }

    func makeClient() throws -> (LLMClient, String) {
        try makeClient(for: settings.providerKind, modelID: settings.modelID)
    }

    /// Embeddings backend — same as chat for Ollama/LM Studio/OpenRouter; separate when Hermes/OpenClaw is selected.
    func makeEmbeddingClient() throws -> (LLMClient, String) {
        let kind = settings.resolvedEmbeddingProviderKind
        let (client, _) = try makeClient(for: kind, modelID: "")
        return (client, settings.resolvedEmbeddingModelID)
    }

    private func makeClient(for kind: LLMProviderKind, modelID: String) throws -> (LLMClient, String) {
        let urlString: String
        switch kind {
        case .ollama: urlString = settings.ollamaURL
        case .lmStudio: urlString = settings.lmStudioURL
        case .openRouter: urlString = settings.openRouterURL
        case .hermes: urlString = settings.hermesURL
        case .openClaw: urlString = settings.openClawURL
        }
        guard let url = URL(string: urlString) else {
            throw SauronError.providerUnreachable(kind.displayName)
        }
        if kind.requiresAPIKey, (KeychainStore.apiKey(for: kind) ?? "").isEmpty {
            throw SauronError.missingAPIKey
        }
        let client = LLMClient(
            kind: kind,
            baseURL: url,
            apiKey: KeychainStore.apiKey(for: kind)
        )
        return (client, modelID)
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
        let alert = settings.promptAlertEnabled
        promptPanel.present(
            RecordPromptView(alertEnabled: alert)
                .environment(self),
            size: GlassChrome.promptSize,
            placement: .topCenter,
            activates: true,
            animated: alert
        )
        if alert {
            PromptAlert.play()
        }
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
        showAssistIfNeeded()
    }

    private func showAssistIfNeeded() {
        assistPanel.present(
            LiveAssistPanelView()
                .environment(self),
            size: GlassChrome.assistSize,
            placement: .leading,
            usesPaneChrome: true
        )
    }

    private func closeLivePanels() {
        transcriptPanel.close()
        assistPanel.close()
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
        liveTranscriptFocusID = nil
        streamPreview = ""
        assistCards = []
        recordingStartedAt = .now
        isMicMuted = false
        status = .recording
        let priority = AudioDeviceCatalog.resolvedPriority(savedIDs: settings.micPriorityIDs)
        micPriorityIndex = 0
        activeMicDisplayName = priority.first?.name ?? "System Default"
        audioMonitor.start(remoteSource: promptAudioSource)
        SpeakerProfileStore.shared.attach(context: modelContext)
        diarizer.setPreferNeural(settings.neuralDiarizationEnabled)
        if settings.neuralDiarizationEnabled || settings.enhanceTranscriptEnabled {
            fluidModels.prepareIfNeeded(enabled: true)
        }
        diarizer.start(profilePrints: SpeakerProfileStore.shared.voiceprints())
        liveAssistant.start()

        do {
            let modes = promptModes
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            if !micOK { throw SauronError.microphoneDenied }
            if modes.contains(.transcript) {
                try await TranscriptionEngine.ensureModel()
                try await transcription.start()
            }
            try await capture.start(
                candidate: candidate,
                modes: modes,
                audioSource: promptAudioSource,
                videoTarget: promptVideoTarget,
                microphoneDeviceID: priority.first?.captureDeviceID,
                echoCancellation: settings.echoCancellationEnabled,
                folder: MediaStore.folder(for: meeting.id)
            )
            // Do not publish media paths yet — the files are still being written.
            // Early report open must not hand AVPlayer an incomplete MP4 (crossed play button).
            try? modelContext.save()
            showTranscript()
        } catch {
            audioMonitor.stop()
            diarizer.stop()
            _ = liveAssistant.stop()
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
        closeLivePanels()
        openReport(meeting)

        await capture.stop()
        diarizer.stop()
        let diarizationTurns = diarizer.timelineTurns()
        let cards = liveAssistant.stop()
        meeting.assistCards = cards
        if meeting.recordTranscript {
            let finals = await transcription.stop()
            if !finals.isEmpty {
                segments = merge(live: segments, finals: finals).map { tagSpeaker($0) }
                liveSegments = segments
                MeetingStore.persist(liveSegments: segments, into: meeting, context: modelContext)
            }
        }
        meeting.videoPath = capture.videoPath
        meeting.micAudioPath = capture.micPath
        meeting.systemAudioPath = capture.systemPath
        mediaReadyToken = UUID()
        try? modelContext.save()

        let folder = MediaStore.folder(for: meeting.id)
        let micURL = capture.micPath.map { URL(fileURLWithPath: $0) }
        let systemURL = capture.systemPath.map { URL(fileURLWithPath: $0) }
        let rawVideoURL = capture.videoPath.map { URL(fileURLWithPath: $0) }

        if meeting.recordTranscript,
           settings.enhanceTranscriptEnabled,
           let asrModels = fluidModels.currentAsrModels() {
            postMeetingPhase = .enhancingTranscript
            if let upgraded = await ParakeetRetranscriber.enhance(
                micURL: micURL,
                systemURL: systemURL,
                turns: diarizationTurns,
                existing: segments,
                models: asrModels
            ) {
                segments = upgraded
                liveSegments = segments
                MeetingStore.persist(liveSegments: segments, into: meeting, context: modelContext)
                try? modelContext.save()
            }
        }

        var mixedURL: URL?
        if meeting.recordAudio || meeting.recordTranscript || meeting.recordVisual {
            postMeetingPhase = .mixingAudio
            do {
                mixedURL = try await MediaCompose.mixAudio(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputURL: MediaCompose.mixedAudioURL(in: folder)
                )
                if let mixedURL {
                    meeting.mixedAudioPath = mixedURL.path
                    mediaReadyToken = UUID()
                    try? modelContext.save()
                }
            } catch {
                lastError = "Mixed audio unavailable: \(error.localizedDescription)"
            }
        }

        if meeting.recordVisual, let rawVideoURL {
            postMeetingPhase = .composingVideo
            do {
                if let composed = try await MediaCompose.muxVideo(
                    videoURL: rawVideoURL,
                    audioURL: mixedURL ?? micURL ?? systemURL,
                    outputURL: MediaCompose.composedVideoURL(in: folder)
                ) {
                    meeting.videoPath = composed.path
                    mediaReadyToken = UUID()
                    try? modelContext.save()
                }
            } catch {
                lastError = "Combined video unavailable: \(error.localizedDescription)"
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
        let transcript = meeting.namedTranscript
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
            let query = "\(meeting.title)\n\(transcript.prefix(800))"
            let injectMemory = settings.shouldInjectMemoryIntoPrompts
            let memory = injectMemory
                ? await MeetingMemoryIndexer.retrieveContext(
                    query: query,
                    appState: self,
                    excludingMeetingID: meeting.id
                )
                : (context: "", citations: [])
            let messages = Summarizer.messages(
                transcript: transcript,
                meetingTitle: meeting.title,
                appName: meeting.appName,
                memoryContext: injectMemory ? memory.context : nil,
                mcpToolHint: injectMemory ? nil : MemoryMCPHints.systemPromptAddon
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
            meeting.memoryCitations = memory.citations
            meeting.status = .ready
            try? modelContext.save()

            TrackedItemStore.sync(from: summary, meeting: meeting, context: modelContext)
            await reconcileTrackedItems(for: meeting, summary: summary, transcript: transcript, client: client, model: model)
            await MeetingMemoryIndexer.index(meeting: meeting, appState: self)
            await scorePresence(for: meeting, transcript: transcript, client: client, model: model)
        } catch {
            meeting.status = transcript.isEmpty ? .ready : .failed
            lastError = error.localizedDescription
            streamPreview = "Transcript saved. Connect a provider in Settings to summarize.\n\n\(error.localizedDescription)"
        }
        try? modelContext.save()
    }

    private func scorePresence(
        for meeting: Meeting,
        transcript: String,
        client: LLMClient,
        model: String
    ) async {
        let selfText = PresenceHeuristicsScorer.selfTranscript(from: meeting)
        let messages = PresenceHeuristicsScorer.messages(
            selfTranscript: selfText,
            fullTranscript: transcript,
            meetingTitle: meeting.title
        )
        do {
            let raw = try await client.complete(model: model, messages: messages)
            if let scores = PresenceHeuristicsScorer.parse(raw) {
                meeting.presence = scores
                try? modelContext.save()
            }
        } catch {
            // Soft-fail: presence scoring is optional.
        }
    }

    private func reconcileTrackedItems(
        for meeting: Meeting,
        summary: MeetingSummary,
        transcript: String,
        client: LLMClient,
        model: String
    ) async {
        let open = TrackedItemStore.openItems(context: modelContext, limit: 50)
            .filter { $0.sourceMeetingID != meeting.id }
        guard !open.isEmpty else { return }
        let payload = open.map { (id: $0.id, kind: $0.kind.rawValue, text: $0.text, owner: $0.owner) }
        let messages = TrackedItemReconciler.messages(
            openItems: payload,
            meetingTitle: meeting.title,
            summaryText: summary.summary,
            transcript: transcript
        )
        do {
            let raw = try await client.complete(model: model, messages: messages)
            let resolutions = TrackedItemReconciler.parse(raw)
            let byID = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0) })
            for resolution in resolutions {
                guard let item = byID[resolution.id] else { continue }
                TrackedItemStore.complete(
                    item,
                    by: .auto,
                    resolvedInMeetingID: meeting.id,
                    note: resolution.note.isEmpty ? nil : resolution.note,
                    context: modelContext
                )
            }
        } catch {
            // Soft-fail: leave open items unchanged.
        }
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
        let tagged = tagSpeaker(segment)
        if tagged.isSelf, !tagged.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            audioMonitor.noteMicSpeechActivity()
        }
        if tagged.isFinal {
            liveAssistant.ingest(final: tagged, appState: self)
        }
        if let index = liveSegments.firstIndex(where: { $0.id == tagged.id }) {
            liveSegments[index] = tagged
        } else {
            liveSegments.append(tagged)
        }
        // Always re-sort — volatile range updates must re-feather You vs remote.
        liveSegments.sort { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.02 {
                return lhs.start < rhs.start
            }
            if abs(lhs.end - rhs.end) > 0.02 {
                return lhs.end < rhs.end
            }
            return lhs.updatedAt < rhs.updatedAt
        }
        liveTranscriptFocusID = tagged.id
    }

    private func tagSpeaker(_ segment: LiveSegment) -> LiveSegment {
        var copy = segment
        if segment.isSelf || SpeakerKey.isSelf(segment.speakerKey) {
            copy.speakerKey = SpeakerKey.selfKey
        } else {
            copy.speakerKey = diarizer.speakerKey(at: segment.start, end: segment.end)
        }
        return copy
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
        diarizer.stop()
        _ = liveAssistant.stop()
        postMeetingPhase = .idle
        isSummarizing = false
        if status == .recording || status == .processing {
            status = settings.watchForMeetings ? .detecting : .idle
            closeLivePanels()
        }
    }
}
