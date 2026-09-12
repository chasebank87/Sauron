import SwiftUI

struct RecordPromptView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    var alertEnabled: Bool = true
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        @Bindable var appState = appState
        let candidate = appState.candidate ?? .simulated()
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ZStack {
                    if alertEnabled {
                        Circle()
                            .stroke(ObserverTheme.accent.opacity(0.35), lineWidth: 2)
                            .frame(width: 36, height: 36)
                            .scaleEffect(pulse ? 1.55 : 0.85)
                            .opacity(pulse ? 0 : 0.7)
                        Image(systemName: "eye.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ObserverTheme.accentGradient)
                            .symbolEffect(.bounce, value: appeared)
                    }
                }
                .frame(height: alertEnabled ? 40 : 0)

                Text("Meeting detected")
                    .font(.headline)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Image(systemName: candidate.kind.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(ObserverTheme.accent)
                    Text(candidate.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)

                if let calendar = candidate.calendarEventTitle {
                    Text(calendar)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .opacity(appeared || !alertEnabled ? 1 : 0)
            .offset(y: appeared || !alertEnabled ? 0 : -8)

            HStack(spacing: 12) {
                ForEach(CaptureMedia.allCases) { media in
                    CaptureMediaCard(
                        media: media,
                        isSelected: appState.promptCapture == media
                    ) {
                        appState.promptCapture = media
                        appState.persistPromptDefaults()
                    }
                }
            }
            .frame(height: 176)
            .padding(.top, 20)

            TranscriptSettingRow(isOn: $appState.promptTranscript)
                .onChange(of: appState.promptTranscript) { _, _ in
                    appState.persistPromptDefaults()
                }
                .padding(.top, 20)

            PromptSettingRow(
                title: "Meeting app only",
                detail: appState.promptMeetingAppAudio
                    ? "Only audio from this meeting app"
                    : "All Mac audio (default)",
                isOn: $appState.promptMeetingAppAudio
            )
            .onChange(of: appState.promptMeetingAppAudio) { _, _ in
                appState.persistPromptDefaults()
            }
            .padding(.top, 10)

            Divider()
                .overlay(ObserverTheme.hairline(for: colorScheme))
                .padding(.top, 18)
                .padding(.bottom, 14)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Not now", action: appState.snoozePrompt)
                        .observerGlassButton()
                    Button("Don’t ask today", action: appState.muteAppToday)
                        .observerGlassButton()
                    Spacer(minLength: 0)
                    Button("Start", action: appState.startRecording)
                        .observerGlassProminentButton()
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: GlassChrome.promptSize.width, height: GlassChrome.promptSize.height)
        .onAppear {
            guard alertEnabled else {
                appeared = true
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                appeared = true
            }
            withAnimation(.easeOut(duration: 0.85).repeatCount(2, autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct CaptureMediaCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let media: CaptureMedia
    let isSelected: Bool
    let action: () -> Void

    private let cardRadius: CGFloat = 15

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: media.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? ObserverTheme.accent : Color.secondary)
                Text(media.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .padding(.top, 12)
                Text(media.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 170)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .fill(isSelected
                          ? ObserverTheme.accent.opacity(0.10)
                          : ObserverTheme.fillQuiet(for: colorScheme))
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? ObserverTheme.accent : ObserverTheme.hairline(for: colorScheme),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(media.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Persistent setting row — not a peer of the mode cards.
private struct TranscriptSettingRow: View {
    @Binding var isOn: Bool

    var body: some View {
        PromptSettingRow(
            title: "Transcript",
            detail: "On-device speech for You and Others",
            isOn: $isOn
        )
    }
}

private struct PromptSettingRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(ObserverTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ObserverTheme.fillSubtle(for: colorScheme))
        }
        .accessibilityElement(children: .combine)
    }
}

struct TranscriptPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var showsAmbient: Bool {
        appState.status == .recording
    }

    var body: some View {
        ZStack {
            if showsAmbient {
                RecordingAmbientBackground()
            } else {
                RoundedRectangle(cornerRadius: ObserverTheme.cardRadius, style: .continuous)
                    .fill(ObserverTheme.panelFallback(for: colorScheme))
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(appState.status == .recording ? 1 : 0.35)
                    Text(appState.status == .processing ? "Wrapping up" : "Recording")
                        .font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(appState.elapsed.observerClock)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                CombinedAudioPresence(
                    monitor: appState.audioMonitor,
                    micLabel: appState.activeMicDisplayName
                )

                if appState.audioMonitor.micSilent || appState.audioMonitor.remoteSilent {
                    VStack(alignment: .leading, spacing: 6) {
                        if appState.audioMonitor.micSilent {
                            SilenceWarningBanner(
                                message: AudioSignalSource.microphone.silentMessage
                            ) {
                                appState.audioMonitor.dismissMicWarning()
                            }
                        }
                        if appState.audioMonitor.remoteSilent {
                            SilenceWarningBanner(
                                message: appState.audioMonitor.remoteSource == .meetingApp
                                    ? AudioSignalSource.meetingApp.silentMessage
                                    : AudioSignalSource.system.silentMessage
                            ) {
                                appState.audioMonitor.dismissRemoteWarning()
                            }
                        }
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if appState.liveSegments.isEmpty {
                                Text(appState.currentMeeting?.recordTranscript == true
                                     ? "Listening…"
                                     : "Recording without a live transcript.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 24)
                            }
                            ForEach(appState.liveSegments) { segment in
                                TranscriptRow(segment: segment)
                                    .id(segment.id)
                            }
                        }
                        // Keep "You" bubbles clear of the faint overlay scroller.
                        .padding(.trailing, 8)
                    }
                    .contentMargins(.trailing, 2, for: .scrollContent)
                    .observerLiquidGlassScroll()
                    .onChange(of: appState.liveSegments.last?.text) { _, _ in
                        if let id = appState.liveSegments.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }

                GlassEffectContainer(spacing: 8) {
                    HStack {
                        Text(modeCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop", action: appState.stopRecording)
                            .observerGlassProminentButton()
                            .disabled(appState.status != .recording)
                    }
                }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: ObserverTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ObserverTheme.cardRadius, style: .continuous)
                .strokeBorder(
                    ObserverTheme.stroke(for: colorScheme, emphasized: showsAmbient),
                    lineWidth: 1
                )
        }
        .frame(width: GlassChrome.transcriptSize.width, height: GlassChrome.transcriptSize.height)
    }

    private var modeCaption: String {
        var parts: [String] = []
        if appState.currentMeeting?.recordVisual == true {
            parts.append(CaptureMedia.videoAndAudio.title)
        } else if appState.currentMeeting?.recordAudio == true {
            parts.append(CaptureMedia.audioOnly.title)
        }
        if appState.currentMeeting?.recordTranscript == true { parts.append("Transcript") }
        parts.append(appState.audioMonitor.remoteSource.liveLabel)
        return parts.isEmpty ? "Recording" : parts.joined(separator: " · ")
    }
}

private struct CombinedAudioPresence: View {
    @Environment(\.colorScheme) private var colorScheme
    let monitor: AudioSignalMonitor
    var micLabel: String = AudioSignalSource.microphone.shortTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Audio")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(monitor.anySilent ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
                sourceChip(
                    title: micLabel,
                    active: monitor.micLevel > 0.03,
                    silent: monitor.micSilent
                )
                sourceChip(
                    title: monitor.remoteSource.liveLabel,
                    active: monitor.remoteLevel > 0.03,
                    silent: monitor.remoteSilent
                )
            }

            ReactiveWaveformLine(
                level: Double(monitor.combinedLevel),
                isAlert: monitor.anySilent
            )
            .frame(height: 48)
            .accessibilityLabel("Combined audio level")
            .accessibilityValue(monitor.anySilent
                                ? "Silent"
                                : "\(Int(monitor.combinedLevel * 100)) percent")
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ObserverTheme.fillSubtle(for: colorScheme))
        }
    }

    private func sourceChip(title: String, active: Bool, silent: Bool) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(silent ? Color.orange : (active ? Color.primary : Color.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(silent
                          ? Color.orange.opacity(0.14)
                          : (active
                             ? ObserverTheme.accent.opacity(0.14)
                             : ObserverTheme.fillQuiet(for: colorScheme)))
            }
    }
}

private struct SilenceWarningBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "speaker.slash.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss", action: dismiss)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(ObserverTheme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        }
    }
}

struct TranscriptRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let segment: LiveSegment

    private var isYou: Bool { segment.isSelf }
    private var displayName: String {
        SpeakerProfileStore.shared.displayName(for: segment.speakerKey)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isYou { Spacer(minLength: 36) }

            VStack(alignment: isYou ? .trailing : .leading, spacing: 4) {
                Text(displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isYou ? ObserverTheme.accent : Color.secondary)

                Text(segment.text)
                    .font(.callout)
                    .foregroundStyle(segment.isFinal ? Color.primary : Color.primary.opacity(0.72))
                    .multilineTextAlignment(isYou ? .trailing : .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isYou
                                  ? ObserverTheme.accent.opacity(colorScheme == .dark ? 0.28 : 0.18)
                                  : ObserverTheme.bubbleOther(for: colorScheme))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isYou
                                    ? ObserverTheme.accent.opacity(0.35)
                                    : ObserverTheme.hairline(for: colorScheme),
                                lineWidth: 1
                            )
                    }
            }
            .frame(maxWidth: 320, alignment: isYou ? .trailing : .leading)

            if !isYou { Spacer(minLength: 36) }
        }
        .opacity(segment.isFinal ? 1 : 0.78)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Observer")
                .font(.headline)
            Text(appState.errorMessage ?? "Something went wrong.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: appState.dismissError)
                    .observerGlassProminentButton()
            }
        }
        .padding(22)
        .frame(width: GlassChrome.errorSize.width, height: GlassChrome.errorSize.height)
    }
}
