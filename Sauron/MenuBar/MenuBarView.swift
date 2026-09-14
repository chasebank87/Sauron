import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            actions
                .padding(.top, 10)
            sectionDivider
            automation
            sectionDivider
            meetings
            sectionDivider
            utility
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            appState.start()
        }
        .onChange(of: appState.reportToken) { _, token in
            if token != nil {
                dismissMenuBar()
                openWindow(id: "report")
            }
        }
        .onChange(of: appState.dashboardToken) { _, token in
            if token != nil {
                dismissMenuBar()
                openWindow(id: "dashboard")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SauronMarkView(size: 22)
            Text("Sauron")
                .font(.headline)
            statusChip
            Spacer(minLength: 6)
            if appState.status == .recording {
                Button {
                    appState.toggleMicMute()
                } label: {
                    Image(systemName: appState.isMicMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(appState.isMicMuted ? .orange : SauronTheme.accent)
                        .frame(width: 32, height: 32)
                        .background {
                            Circle()
                                .fill(appState.isMicMuted ? Color.orange.opacity(0.14) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appState.isMicMuted ? "Unmute mic" : "Mute mic")
                .accessibilityAddTraits(appState.isMicMuted ? .isSelected : [])
                .help(appState.isMicMuted ? "Unmute mic" : "Mute mic")

                Button("Stop", action: appState.stopRecording)
                    .observerGlassProminentButton()
                    .controlSize(.small)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                dismissMenuBar()
                appState.openDashboard()
                openWindow(id: "dashboard")
            } label: {
                Label("Open Dashboard", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .observerGlassProminentButton()

            Button {
                appState.simulateMeeting()
            } label: {
                Label("Simulate meeting", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .observerGlassButton()
            .disabled(appState.status == .recording || appState.status == .processing)
        }
    }

    private var automation: some View {
        Toggle(isOn: Bindable(appState.settings).watchForMeetings) {
            Text("Auto-detect meetings")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SauronTheme.textPrimary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onChange(of: appState.settings.watchForMeetings) { _, _ in
            appState.beginDetectionIfNeeded()
        }
        .padding(.vertical, 2)
        .accessibilityHint("Look for Zoom, Meet, Teams, FaceTime, Webex, and Slack huddles.")
    }

    private var meetings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let items = appState.recentMeetings
            if items.isEmpty {
                Text("Meetings you record will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(items.prefix(8))) { meeting in
                    MenuBarMeetingRow(meeting: meeting) {
                        dismissMenuBar()
                        appState.openReport(meeting)
                        openWindow(id: "report")
                    }
                }
            }
        }
    }

    private var utility: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Settings") {
                dismissMenuBar()
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            .observerGlassButton()

            Button("Quit Sauron") {
                dismissMenuBar()
                NSApp.terminate(nil)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SauronTheme.red.opacity(0.78))
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 10)
    }

    private var statusChip: some View {
        chipLabel(title: MenuBarPresentation.chipTitle(for: appState.status))
    }

    private func chipLabel(title: String) -> some View {
        let color = MenuBarPresentation.chipColor(for: appState.status)
        let isLive = MenuBarPresentation.chipIsLive(appState.status)
        return HStack(spacing: 6) {
            MenuBarLiveDot(color: color, isLive: isLive)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SauronTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SauronTheme.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status")
        .accessibilityValue(title)
    }

    /// Close the MenuBarExtra popover before opening another window.
    private func dismissMenuBar() {
        dismiss()
        // `.menuBarExtraStyle(.window)` often ignores Environment dismiss — close it by class.
        for window in NSApp.windows {
            let name = NSStringFromClass(type(of: window))
            if name.contains("MenuBarExtra") || name.contains("StatusItem") {
                window.orderOut(nil)
            }
        }
    }
}

struct MenuBarLabel: View {
    var status: AppStatus

    var body: some View {
        SauronMenuBarMark(status: status)
    }
}

enum MenuBarPresentation {
    static func chipTitle(for status: AppStatus) -> String {
        switch status {
        case .idle: "Idle"
        case .detecting: "Watching"
        case .prompt: "Meeting detected"
        case .recording: "Recording"
        case .processing: "Writing report"
        }
    }

    static func chipIsLive(_ status: AppStatus) -> Bool {
        status != .idle
    }

    static func chipColor(for status: AppStatus) -> Color {
        switch status {
        case .recording: SauronTheme.ember
        case .processing, .prompt: SauronTheme.amber
        case .detecting: SauronTheme.mint
        case .idle: SauronTheme.textTertiary
        }
    }

    static func recentIsGenerated(_ kind: MeetingKind) -> Bool {
        kind == .simulated
    }

    static func recentSystemImage(for kind: MeetingKind) -> String {
        recentIsGenerated(kind) ? "sparkles" : "person.2.fill"
    }

    static func recentAccent(for kind: MeetingKind) -> Color {
        recentIsGenerated(kind) ? SauronTheme.irisEnd : SauronTheme.irisStart
    }
}

private struct MenuBarLiveDot: View {
    var color: Color
    var isLive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isLive {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.85)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 12, height: 12)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: isLive) { _, _ in
            pulse = false
            startPulseIfNeeded()
        }
    }

    private func startPulseIfNeeded() {
        guard isLive else { return }
        withAnimation(.easeOut(duration: 1.35).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

private struct MenuBarMeetingRow: View {
    let meeting: Meeting
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MenuBarRecentGlyph(kind: meeting.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title)
                        .foregroundStyle(SauronTheme.textPrimary)
                        .lineLimit(1)
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                hovered ? SauronTheme.fillSubtle(for: colorScheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: SauronTheme.radiusControl, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: SauronTheme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(meeting.title), \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct MenuBarRecentGlyph: View {
    let kind: MeetingKind

    var body: some View {
        let color = MenuBarPresentation.recentAccent(for: kind)
        Image(systemName: MenuBarPresentation.recentSystemImage(for: kind))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 26, height: 26)
            .background(
                color.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
