import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actions
            Divider()
            meetings
            Divider()
            footer
        }
        .padding(14)
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
        HStack {
            SauronMarkView(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sauron")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        VStack(spacing: 8) {
            Button {
                dismissMenuBar()
                appState.openDashboard()
                openWindow(id: "dashboard")
            } label: {
                Label("Open Dashboard", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .observerGlassButton()

            Button {
                appState.simulateMeeting()
            } label: {
                Label("Simulate meeting", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .observerGlassButton()
            .disabled(appState.status == .recording || appState.status == .processing)

            Toggle("Watch for meetings", isOn: Bindable(appState.settings).watchForMeetings)
                .onChange(of: appState.settings.watchForMeetings) { _, _ in
                    appState.beginDetectionIfNeeded()
                }
        }
    }

    private var meetings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let items = appState.recentMeetings
            if items.isEmpty {
                Text("Meetings you record will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(items.prefix(8))) { meeting in
                    Button {
                        dismissMenuBar()
                        appState.openReport(meeting)
                        openWindow(id: "report")
                    } label: {
                        HStack {
                            Image(systemName: meeting.kind.systemImage)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title)
                                    .lineLimit(1)
                                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings") {
                dismissMenuBar()
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            .observerGlassButton()
            Spacer()
            Button("Quit Sauron") {
                dismissMenuBar()
                NSApp.terminate(nil)
            }
            .observerGlassButton()
        }
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

    private var statusText: String {
        switch appState.status {
        case .idle: "Idle"
        case .detecting: "Watching for meetings"
        case .prompt: "Meeting detected"
        case .recording: "Recording"
        case .processing: "Writing report"
        }
    }
}

struct MenuBarLabel: View {
    var status: AppStatus

    var body: some View {
        SauronMenuBarMark(status: status)
    }
}
