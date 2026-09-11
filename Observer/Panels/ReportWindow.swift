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
        .frame(minWidth: 640, minHeight: 520)
        .background(.clear)
    }
}

struct ReportDetailView: View {
    @Bindable var meeting: Meeting
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if meeting.hasPlayableMedia {
                    recordingsCard
                }
                if appState.isSummarizing
                    || appState.postMeetingPhase != .idle
                    || meeting.status == .processing {
                    streamingCard
                }
                if let summary = meeting.summary {
                    summarySections(summary)
                } else if meeting.status == .failed {
                    GlassCard {
                        Text(appState.streamPreview.isEmpty
                             ? "Transcript saved. Connect Ollama, LM Studio, or OpenRouter in Settings to summarize."
                             : appState.streamPreview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                transcriptCard
            }
            .padding(24)
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

    private var recordingsCard: some View {
        reportBlock(title: "Recording", systemImage: "play.rectangle") {
            VStack(alignment: .leading, spacing: 14) {
                if let videoURL = meeting.playableVideoURL {
                    MediaPlayerView(url: videoURL, height: 280)
                }
                if let mixedURL = meeting.playableMixedURL {
                    audioRow(title: "Mixed audio", url: mixedURL)
                }
                if meeting.playableMicURL != nil || meeting.playableSystemURL != nil {
                    DisclosureGroup("Separate tracks") {
                        VStack(alignment: .leading, spacing: 12) {
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
            MediaPlayerView(url: url, height: 48)
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
                    .tint(ObserverTheme.accent)

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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.actionItems) { item in
                        let owner = item.owner.map { "\($0): " } ?? ""
                        Text("\(owner)\(item.text)")
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

    private var transcriptCard: some View {
        reportBlock(title: "Transcript", systemImage: "text.bubble") {
            let text = meeting.plainTranscript
            if text.isEmpty {
                Text("No transcript captured")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
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

/// AppKit-backed player — SwiftUI `VideoPlayer` fatals under some macOS 26 / AVKit metadata paths.
private struct MediaPlayerView: NSViewRepresentable {
    let url: URL
    var height: CGFloat = 200

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        guard current != url else { return }
        nsView.player?.pause()
        nsView.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: height)
    }
}
