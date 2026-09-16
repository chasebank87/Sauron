import AVFoundation
import AVKit
import AppKit
import SwiftUI

struct ReportWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let meeting = appState.selectedMeeting {
                ReportDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "No meeting selected",
                    systemImage: "doc.text",
                    description: Text("Choose a meeting from the menu bar.")
                )
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(.clear)
    }
}

struct ReportDetailView: View {
    @Bindable var meeting: Meeting
    @Environment(AppState.self) private var appState
    @State private var newPersonName = ""
    @State private var assigningKey: String?
    @State private var playback = ReportPlaybackController()
    @State private var editingTranscript = false
    /// Sorted once; refreshed only when segment identity/count changes — never inside body layout.
    @State private var sortedSegments: [TranscriptSegment] = []
    @Environment(\.colorScheme) private var colorScheme

    private var speakerStore: SpeakerProfileStore { SpeakerProfileStore.shared }

    private var remoteSpeakerKeys: [String] {
        let keys = Set(meeting.segments.map(\.speakerKey).filter { !SpeakerKey.isSelf($0) })
        return keys.sorted { lhs, rhs in
            let li = SpeakerKey.clusterIndex(lhs) ?? Int.max
            let ri = SpeakerKey.clusterIndex(rhs) ?? Int.max
            if li != ri { return li < ri }
            return speakerStore.displayName(for: lhs) < speakerStore.displayName(for: rhs)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if meeting.hasPlayableMedia || !sortedSegments.isEmpty {
                    playbackAndTranscriptSection
                }
                documentsCard
                userNotesCard
                if appState.isSummarizing
                    || appState.postMeetingPhase != .idle
                    || meeting.status == .processing {
                    streamingCard
                }
                if isStuckProcessing {
                    stuckProcessingCard
                }
                if let summary = meeting.summary {
                    summarySections(summary)
                    HStack(spacing: 8) {
                        updateSummaryButton
                        reprocessButton
                    }
                } else if meeting.status == .failed {
                    GlassCard {
                        Text(appState.streamPreview.isEmpty
                             ? "Transcript saved. Connect Ollama, LM Studio, or OpenRouter in Settings to summarize."
                             : appState.streamPreview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        updateSummaryButton
                        reprocessButton
                    }
                }
                if !meeting.memoryCitations.isEmpty {
                    memoryCitationsCard
                }
                if !meeting.assistCards.isEmpty {
                    researchCard
                }
                if !remoteSpeakerKeys.isEmpty {
                    speakersCard
                }
            }
            .padding(24)
        }
        .onAppear {
            speakerStore.attach(context: appState.modelContext)
            refreshSortedSegments()
        }
        .onChange(of: meeting.segments.count) { _, _ in
            refreshSortedSegments()
        }
        .onChange(of: meeting.status) { _, _ in
            refreshSortedSegments()
        }
        .onChange(of: appState.mediaReadyToken) { _, _ in
            refreshSortedSegments()
        }
    }

    private func refreshSortedSegments() {
        sortedSegments = meeting.segments.sorted { $0.start < $1.start }
    }

    @ViewBuilder
    private var playbackAndTranscriptSection: some View {
        let hasMedia = meeting.hasPlayableMedia
        let hasTranscript = !sortedSegments.isEmpty

        if hasMedia && hasTranscript {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    recordingsCard
                        .frame(maxWidth: .infinity)
                    syncedTranscriptCard(height: 360)
                        .frame(maxWidth: 380)
                }
                VStack(alignment: .leading, spacing: 16) {
                    recordingsCard
                    syncedTranscriptCard(height: 320)
                }
            }
        } else if hasMedia {
            recordingsCard
        } else {
            syncedTranscriptCard(height: 360)
        }
    }

    private var updateSummaryButton: some View {
        Button("Update summary") {
            appState.resummarize(meeting)
        }
        .observerGlassButton()
        .disabled(appState.isSummarizing || meeting.namedTranscript.isEmpty)
    }

    /// Unlike `updateSummaryButton` (re-runs the AI summary only), this redoes the
    /// whole post-recording pipeline against the raw saved media: diarization,
    /// transcript enhancement, audio mixing, video composition, then the summary.
    private var reprocessButton: some View {
        Button("Reprocess recording") {
            appState.reprocessMeeting(meeting)
        }
        .observerGlassButton()
        .disabled(appState.isSummarizing || !meeting.hasPlayableMedia)
    }

    /// True for a meeting left at `.processing` from a previous session (app quit
    /// or crashed mid-pipeline, or hit a bug) with nothing currently working on it
    /// -- as opposed to one actively processing right now, which already shows
    /// `streamingCard`.
    private var isStuckProcessing: Bool {
        meeting.status == .processing
            && appState.postMeetingPhase == .idle
            && !appState.isSummarizing
    }

    private var stuckProcessingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("This meeting's report never finished", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                Text("Processing was interrupted (e.g. the app quit or hit an error) after recording stopped. The raw recording is safe -- reprocess to re-run transcript enhancement, the mixed audio, combined video, and summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reprocess") {
                    appState.reprocessMeeting(meeting)
                }
                .observerGlassButton()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(meeting.kind.displayName, systemImage: meeting.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(meeting.title)
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 12) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text(meeting.duration.observerClock)
                Text(meeting.recordVisual ? CaptureMedia.videoAndAudio.title : CaptureMedia.audioOnly.title)
                if meeting.recordTranscript { Text("Transcript") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var documentsCard: some View {
        reportBlock(title: "Documents", systemImage: "paperclip") {
            MeetingDocumentsSection(meeting: meeting, compact: false)
        }
    }

    private var userNotesCard: some View {
        reportBlock(title: "Your notes", systemImage: "square.and.pencil") {
            MeetingUserNotesEditor(meeting: meeting)
        }
    }

    private var recordingsCard: some View {
        reportBlock(title: "Recording", systemImage: "play.rectangle") {
            VStack(alignment: .leading, spacing: 14) {
                if appState.postMeetingPhase == .savingCapture {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finalizing recording…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let videoURL = meeting.playableVideoURL {
                    MediaPlayerView(
                        url: videoURL,
                        audioURL: meeting.playableMixedURL,
                        height: 280,
                        reloadToken: appState.mediaReadyToken,
                        playback: playback,
                        allowsFullScreen: true
                    )
                } else if let mixedURL = meeting.playableMixedURL {
                    MediaPlayerView(
                        url: mixedURL,
                        height: 56,
                        reloadToken: appState.mediaReadyToken,
                        playback: playback
                    )
                }
                if meeting.playableMixedURL != nil
                    || meeting.playableMicURL != nil
                    || meeting.playableSystemURL != nil {
                    DisclosureGroup("Audio tracks") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let mixedURL = meeting.playableMixedURL {
                                audioRow(title: "Mixed audio", url: mixedURL)
                            }
                            if let micURL = meeting.playableMicURL {
                                audioRow(title: "Microphone", url: micURL)
                            }
                            if let systemURL = meeting.playableSystemURL {
                                audioRow(title: "System audio", url: systemURL)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func audioRow(title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            MediaPlayerView(url: url, height: 48, reloadToken: appState.mediaReadyToken)
        }
    }

    private var streamingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.postMeetingPhase == .idle
                         ? "Writing report"
                         : appState.postMeetingPhase.title)
                        .font(.headline)
                    Spacer()
                }

                ProgressView(value: appState.postMeetingPhase.progress, total: 1)
                    .tint(SauronTheme.accent)

                if appState.postMeetingPhase == .summarizing, !appState.streamPreview.isEmpty {
                    Text(appState.streamPreview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                } else if appState.postMeetingPhase != .idle {
                    Text("You can keep this window open — the report fills in as each step finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySections(_ summary: MeetingSummary) -> some View {
        if !summary.summary.isEmpty {
            reportBlock(title: "Summary", systemImage: "text.justify") {
                Text(summary.summary)
                    .textSelection(.enabled)
            }
        }
        let people = summary.keyPeople.isEmpty ? transcriptPeople : summary.keyPeople
        if !people.isEmpty {
            reportBlock(title: "Key people", systemImage: "person.2") {
                FlowPeopleRow(names: people)
            }
        }
        if !summary.topics.isEmpty {
            reportBlock(title: "Topics", systemImage: "tag") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.topics, id: \.self) { item in
                        Label(item, systemImage: "number")
                    }
                }
            }
        }
        if !summary.notes.isEmpty {
            reportBlock(title: "Notes", systemImage: "note.text") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.notes, id: \.self) { item in
                        Text(item)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        if !summary.decisions.isEmpty {
            reportBlock(title: "Decisions", systemImage: "checkmark.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.decisions, id: \.self) { item in
                        Label(item, systemImage: "checkmark")
                    }
                }
            }
        }
        if !summary.actionItems.isEmpty {
            reportBlock(title: "Action items", systemImage: "checklist") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.actionItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "circle")
                                    .font(.caption)
                                    .foregroundStyle(SauronTheme.accent)
                                Text(item.text)
                                    .textSelection(.enabled)
                            }
                            HStack(spacing: 8) {
                                if let owner = item.owner, !owner.isEmpty {
                                    Text(owner)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                if let due = item.due, !due.isEmpty {
                                    Text("Due \(due)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
            }
        }
        if !summary.nextSteps.isEmpty {
            reportBlock(title: "Next steps", systemImage: "arrow.right.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.nextSteps, id: \.self) { item in
                        Label(item, systemImage: "arrow.turn.down.right")
                    }
                }
            }
        }
        if !summary.blockers.isEmpty {
            reportBlock(title: "Blockers & risks", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.blockers, id: \.self) { item in
                        Label(item, systemImage: "exclamationmark.circle")
                    }
                }
            }
        }
        if !summary.openQuestions.isEmpty {
            reportBlock(title: "Open questions", systemImage: "questionmark.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.openQuestions, id: \.self) { item in
                        Text(item)
                    }
                }
            }
        }
        if !summary.quotes.isEmpty {
            reportBlock(title: "Quotes", systemImage: "quote.opening") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.quotes, id: \.self) { item in
                        Text("“\(item)”")
                            .italic()
                    }
                }
            }
        }
    }

    private var transcriptPeople: [String] {
        let names = Set(meeting.segments.map { speakerStore.displayName(for: $0.speakerKey) })
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func syncedTranscriptCard(height: CGFloat) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("Transcript", systemImage: "text.bubble")
                        .font(.headline)
                    if meeting.hasPlayableMedia {
                        ReportPlaybackClockBadge(playback: playback)
                    }
                    Spacer(minLength: 0)
                    if !editingTranscript {
                        Button {
                            playback.followTranscript.toggle()
                        } label: {
                            Image(systemName: playback.followTranscript
                                  ? "location.fill.viewfinder"
                                  : "location.viewfinder")
                        }
                        .help(playback.followTranscript
                              ? "Auto-scroll is on"
                              : "Auto-scroll is off")
                        .font(.caption.weight(.semibold))
                        .observerGlassButton()
                    }
                    Button(editingTranscript ? "Done" : "Edit") {
                        editingTranscript.toggle()
                    }
                    .font(.caption.weight(.semibold))
                    .observerGlassButton()
                }

                if sortedSegments.isEmpty {
                    Text("No transcript captured")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: height * 0.4, alignment: .center)
                } else if editingTranscript {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(sortedSegments, id: \.id) { segment in
                                editableTranscriptRow(segment)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(height: height)
                    .scrollIndicators(.hidden)
                } else {
                    SyncedTranscriptList(
                        segments: sortedSegments,
                        playback: playback,
                        displayName: { speakerStore.displayName(for: $0) },
                        colorScheme: colorScheme
                    )
                    .frame(height: height)
                }
            }
        }
    }

    private var speakersCard: some View {
        reportBlock(title: "Speakers", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Assign auto-detected remote speakers to people in Settings → People.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(remoteSpeakerKeys, id: \.self) { key in
                    HStack(alignment: .center, spacing: 10) {
                        Text(speakerStore.displayName(for: key))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 110, alignment: .leading)
                        Picker(
                            "Assign",
                            selection: Binding(
                                get: { key },
                                set: { newValue in
                                    applyAssignment(from: key, selection: newValue)
                                }
                            )
                        ) {
                            Text(SpeakerKey.fallbackDisplayName(key)).tag(key)
                            ForEach(speakerStore.otherProfiles, id: \.id) { profile in
                                Text(profile.name).tag(profile.speakerKey)
                            }
                            Text("New person…").tag("__new__:\(key)")
                        }
                        .labelsHidden()
                    }
                    if assigningKey == key {
                        HStack {
                            TextField("Name", text: $newPersonName)
                                .onSubmit { createAssignedPerson(from: key) }
                            Button("Add") { createAssignedPerson(from: key) }
                                .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") {
                                assigningKey = nil
                                newPersonName = ""
                            }
                        }
                    }
                }
            }
        }
    }

    private var researchCard: some View {
        reportBlock(title: "Research & fact-checks", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(meeting.assistCards) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(card.title, systemImage: card.kind.systemImage)
                                .font(.subheadline.weight(.semibold))
                            if let verdict = card.verdict {
                                Text(verdict.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(card.body)
                            .font(.callout)
                            .textSelection(.enabled)
                        ForEach(card.sources) { source in
                            if source.url.hasPrefix("http"), let url = URL(string: source.url) {
                                Link(source.title, destination: url)
                                    .font(.caption)
                            } else {
                                Text(source.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var memoryCitationsCard: some View {
        reportBlock(title: "From past meetings", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(meeting.memoryCitations) { citation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(citation.meetingTitle)
                            .font(.subheadline.weight(.semibold))
                        Text(citation.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func editableTranscriptRow(_ segment: TranscriptSegment) -> some View {
        let isSelf = segment.isSelf
        return VStack(alignment: isSelf ? .trailing : .leading, spacing: 6) {
            HStack {
                if isSelf { Spacer(minLength: 24) }
                Text(segment.start.observerClock)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Picker(
                    "Speaker",
                    selection: Binding(
                        get: { segment.speakerKey },
                        set: { newKey in
                            segment.speakerKey = newKey
                            try? appState.modelContext.save()
                        }
                    )
                ) {
                    Text(speakerStore.displayName(for: SpeakerKey.selfKey))
                        .tag(SpeakerKey.selfKey)
                    ForEach(remotePickerOptions(current: segment.speakerKey), id: \.self) { key in
                        Text(speakerStore.displayName(for: key)).tag(key)
                    }
                    ForEach(speakerStore.otherProfiles, id: \.id) { profile in
                        Text(profile.name).tag(profile.speakerKey)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                if !isSelf { Spacer(minLength: 24) }
            }
            TextField(
                "Transcript line",
                text: Binding(
                    get: { segment.text },
                    set: { newValue in
                        segment.text = newValue
                        try? appState.modelContext.save()
                    }
                ),
                axis: .vertical
            )
            .font(.callout)
            .lineLimit(2...8)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelf
                          ? SauronTheme.accent.opacity(colorScheme == .dark ? 0.22 : 0.12)
                          : SauronTheme.bubbleOther(for: colorScheme))
            }
        }
    }

    private func remotePickerOptions(current: String) -> [String] {
        var keys = Set(remoteSpeakerKeys)
        keys.insert(current)
        keys = keys.filter { !SpeakerKey.isSelf($0) }
        return keys.sorted()
    }

    private func applyAssignment(from sourceKey: String, selection: String) {
        if selection.hasPrefix("__new__:") {
            assigningKey = sourceKey
            newPersonName = ""
            return
        }
        if selection == sourceKey { return }
        if let id = SpeakerKey.profileID(selection),
           let profile = speakerStore.profiles.first(where: { $0.id == id }) {
            appState.assignSpeaker(from: sourceKey, to: profile, in: meeting)
        }
    }

    private func createAssignedPerson(from sourceKey: String) {
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        appState.createAndAssignSpeaker(name: name, from: sourceKey, in: meeting)
        assigningKey = nil
        newPersonName = ""
    }

    private func reportBlock<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let body = content()
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                body
                    .font(.body)
            }
        }
    }
}

/// Lightweight timing row for playback ↔ transcript sync (no SwiftData access on the clock path).
struct ReportSegmentTiming: Equatable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
}

enum ReportTranscriptSync {
    /// Returns the segment that should highlight at playback time `t`.
    static func activeSegmentID(at t: TimeInterval, in segments: [ReportSegmentTiming]) -> UUID? {
        guard !segments.isEmpty else { return nil }
        if let exact = segments.first(where: { t >= $0.start && t <= max($0.end, $0.start + 0.05) }) {
            return exact.id
        }
        let started = segments.filter { $0.start <= t }
        return started.last?.id ?? segments.first?.id
    }
}

/// Isolates `currentTime` observation so the large report tree is not invalidated every tick.
private struct ReportPlaybackClockBadge: View {
    @Bindable var playback: ReportPlaybackController

    var body: some View {
        if playback.isPlaying || playback.currentTime > 0 {
            Text(playback.currentTime.observerClock)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(SauronTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(SauronTheme.accent.opacity(0.12)))
        }
    }
}

/// Shared playback clock for syncing the report transcript to video/audio.
@Observable
@MainActor
final class ReportPlaybackController {
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var duration: TimeInterval = 0
    var activeSegmentID: UUID?
    /// When true, the transcript pane keeps the spoken line centered.
    var followTranscript = true

    @ObservationIgnored weak var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingSeek: TimeInterval?
    @ObservationIgnored private var segmentsForSync: [ReportSegmentTiming] = []

    func updateSegments(_ segments: [TranscriptSegment]) {
        segmentsForSync = segments.map {
            ReportSegmentTiming(id: $0.id, start: $0.start, end: $0.end)
        }
        refreshActiveSegment()
    }

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        // ~4 Hz is enough for clock + segment highlight; 50ms was thrashing the report UI.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = max(0, seconds)
                self.refreshActiveSegment()
            }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.rate > 0
            }
        }
        Task { @MainActor in
            if let item = player.currentItem {
                let loaded = try? await item.asset.load(.duration)
                if let loaded, loaded.seconds.isFinite {
                    self.duration = max(0, loaded.seconds)
                }
            }
            if let pendingSeek {
                seek(to: pendingSeek)
                self.pendingSeek = nil
            }
            refreshActiveSegment()
        }
    }

    func detach() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        rateObservation?.invalidate()
        rateObservation = nil
        player = nil
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, seconds)
        guard let player else {
            pendingSeek = clamped
            currentTime = clamped
            refreshActiveSegment()
            return
        }
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        refreshActiveSegment()
    }

    private func refreshActiveSegment() {
        let newID = ReportTranscriptSync.activeSegmentID(at: currentTime, in: segmentsForSync)
        if activeSegmentID != newID {
            activeSegmentID = newID
        }
    }
}

private struct FlowPeopleRow: View {
    let names: [String]

    var body: some View {
        FlexibleNameWrap(names: names)
    }
}

/// Simple wrapping chips without a dependency on Layout protocol gymnastics.
private struct FlexibleNameWrap: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { name in
                        Text(name)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(SauronTheme.accent.opacity(0.12)))
                            .foregroundStyle(SauronTheme.accent)
                    }
                }
            }
        }
    }

    private var rows: [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var width = 0
        for name in names {
            let estimate = name.count + 4
            if !current.isEmpty, width + estimate > 42 {
                result.append(current)
                current = [name]
                width = estimate
            } else {
                current.append(name)
                width += estimate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private struct SyncedTranscriptList: View {
    let segments: [TranscriptSegment]
    @Bindable var playback: ReportPlaybackController
    let displayName: (String) -> String
    let colorScheme: ColorScheme
    @State private var lastScrolledID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments, id: \.id) { segment in
                        let active = playback.activeSegmentID == segment.id
                        SyncedTranscriptBubble(
                            segment: segment,
                            name: displayName(segment.speakerKey),
                            isActive: active,
                            colorScheme: colorScheme
                        )
                        .id(segment.id)
                        .onTapGesture {
                            playback.followTranscript = true
                            playback.seek(to: segment.start)
                            if playback.player?.rate == 0 {
                                playback.player?.play()
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                playback.updateSegments(segments)
                scrollToActive(proxy: proxy, force: true)
            }
            .onChange(of: segments.count) { _, _ in
                playback.updateSegments(segments)
            }
            .onChange(of: playback.activeSegmentID) { _, _ in
                scrollToActive(proxy: proxy, force: false)
            }
            .onChange(of: playback.isPlaying) { _, playing in
                if playing { scrollToActive(proxy: proxy, force: true) }
            }
            .onChange(of: playback.followTranscript) { _, enabled in
                if enabled { scrollToActive(proxy: proxy, force: true) }
            }
        }
    }

    private func scrollToActive(proxy: ScrollViewProxy, force: Bool) {
        guard playback.followTranscript else { return }
        guard let id = playback.activeSegmentID else { return }
        guard force || id != lastScrolledID else { return }
        lastScrolledID = id
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct SyncedTranscriptBubble: View {
    let segment: TranscriptSegment
    let name: String
    let isActive: Bool
    let colorScheme: ColorScheme

    private var isSelf: Bool { segment.isSelf }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isSelf { Spacer(minLength: 36) }

            VStack(alignment: isSelf ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelf ? SauronTheme.accent : Color.secondary)
                    Text(segment.start.observerClock)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(segment.text)
                    .font(.callout)
                    .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.72))
                    .multilineTextAlignment(isSelf ? .trailing : .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(bubbleFill)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(bubbleStroke, lineWidth: isActive ? 1.5 : 1)
                    }
                    .shadow(
                        color: isActive ? SauronTheme.accent.opacity(0.18) : .clear,
                        radius: isActive ? 8 : 0,
                        y: 1
                    )
            }
            .frame(maxWidth: 280, alignment: isSelf ? .trailing : .leading)

            if !isSelf { Spacer(minLength: 36) }
        }
        .scaleEffect(isActive ? 1.015 : 1)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .opacity(isActive ? 1 : 0.78)
    }

    private var bubbleFill: Color {
        if isActive {
            return isSelf
                ? SauronTheme.accent.opacity(colorScheme == .dark ? 0.36 : 0.22)
                : SauronTheme.accent.opacity(colorScheme == .dark ? 0.18 : 0.10)
        }
        return isSelf
            ? SauronTheme.accent.opacity(colorScheme == .dark ? 0.22 : 0.12)
            : SauronTheme.bubbleOther(for: colorScheme)
    }

    private var bubbleStroke: Color {
        if isActive {
            return SauronTheme.accent.opacity(0.55)
        }
        return isSelf
            ? SauronTheme.accent.opacity(0.28)
            : SauronTheme.hairline(for: colorScheme)
    }
}

/// AppKit-backed player — SwiftUI `VideoPlayer` fatals under some macOS 26 / AVKit metadata paths.
private struct MediaPlayerView: NSViewRepresentable {
    let url: URL
    /// Optional sidecar audio (used when `url` is silent video and mux isn't ready yet).
    var audioURL: URL? = nil
    var height: CGFloat = 200
    /// Changes when capture/mix finishes so we reload a finalized file (same URL).
    var reloadToken: UUID = UUID()
    var playback: ReportPlaybackController? = nil
    /// Shows AVKit's native fullscreen/theater toggle — only meaningful when `url` has video.
    var allowsFullScreen: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = allowsFullScreen
        context.coordinator.load(
            url: url,
            audioURL: audioURL,
            into: view,
            token: reloadToken,
            playback: playback
        )
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.load(
            url: url,
            audioURL: audioURL,
            into: nsView,
            token: reloadToken,
            playback: playback
        )
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.playback?.detach()
        nsView.player?.pause()
        nsView.player = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: height)
    }

    @MainActor
    final class Coordinator {
        private var loadedVideo: URL?
        private var loadedAudio: URL?
        private var loadedToken: UUID?
        var playback: ReportPlaybackController?

        func load(
            url: URL,
            audioURL: URL?,
            into view: AVPlayerView,
            token: UUID,
            playback: ReportPlaybackController?
        ) {
            self.playback = playback
            if loadedVideo == url, loadedAudio == audioURL, loadedToken == token, view.player != nil {
                if let player = view.player, playback?.player !== player {
                    playback?.attach(player)
                }
                return
            }
            loadedVideo = url
            loadedAudio = audioURL
            loadedToken = token
            view.player?.pause()
            playback?.detach()

            Task { @MainActor in
                let player = await Self.makePlayer(videoURL: url, audioURL: audioURL)
                guard self.loadedToken == token, self.loadedVideo == url else { return }
                view.player = player
                playback?.attach(player)
            }
        }

        private static func makePlayer(videoURL: URL, audioURL: URL?) async -> AVPlayer {
            // Once MediaCompose has muxed the recording, the video already carries the
            // mixed audio as its own track — compositing again here would just rebuild
            // the same thing and, worse, race MediaCompose's own composition teardown on
            // the same shared CoreMedia queues (this has crashed with SIGSEGV). Only
            // composite when the video is still the raw, video-only capture.
            if let audioURL {
                let videoAsset = AVURLAsset(url: videoURL)
                let hasOwnAudio = (try? await videoAsset.loadTracks(withMediaType: .audio).isEmpty) == false
                if !hasOwnAudio {
                    await MediaCompositionGate.shared.acquire()
                    defer {
                        let gate = MediaCompositionGate.shared
                        Task { await gate.release() }
                    }
                    do {
                        let composition = AVMutableComposition()
                        let audioAsset = AVURLAsset(url: audioURL)
                        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
                        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
                        let videoDuration = try await videoAsset.load(.duration)
                        let audioDuration = try await audioAsset.load(.duration)

                        if let sourceVideo = videoTracks.first,
                           let compositionVideo = composition.addMutableTrack(
                                withMediaType: .video,
                                preferredTrackID: kCMPersistentTrackID_Invalid
                           ) {
                            try compositionVideo.insertTimeRange(
                                CMTimeRange(start: .zero, duration: videoDuration),
                                of: sourceVideo,
                                at: .zero
                            )
                            compositionVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
                        }

                        if let sourceAudio = audioTracks.first,
                           let compositionAudio = composition.addMutableTrack(
                                withMediaType: .audio,
                                preferredTrackID: kCMPersistentTrackID_Invalid
                           ) {
                            let insertDuration = CMTimeMinimum(audioDuration, videoDuration)
                            try compositionAudio.insertTimeRange(
                                CMTimeRange(start: .zero, duration: insertDuration),
                                of: sourceAudio,
                                at: .zero
                            )
                        }

                        return AVPlayer(playerItem: AVPlayerItem(asset: composition))
                    } catch {
                        return AVPlayer(url: videoURL)
                    }
                }
            }

            return AVPlayer(url: videoURL)
        }
    }
}
