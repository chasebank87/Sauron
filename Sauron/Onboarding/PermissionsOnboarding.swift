import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Speech
import SwiftUI
import UserNotifications

struct PermissionStatus: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var granted: Bool
    var required: Bool
    var systemImage: String
}

private final class CalendarAccessClient: @unchecked Sendable {
    private let store = EKEventStore()

    func requestFullAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
enum PermissionService {
    private static let calendarClient = CalendarAccessClient()

    static func snapshot() async -> [PermissionStatus] {
        let screenGranted = ScreenCaptureAccess.granted()
        let windowGranted = await WindowShareAccess.granted()
        return [
            PermissionStatus(
                id: "screen",
                title: "Screen Recording",
                detail: screenGranted
                    ? "Meeting window and system audio"
                    : ScreenCaptureAccess.wasRequested
                        ? "Settings can show this as on while a debug build is still unsigned."
                        : "Meeting window and system audio",
                granted: screenGranted,
                required: true,
                systemImage: "rectangle.dashed.badge.record"
            ),
            PermissionStatus(
                id: "windows",
                title: "App & Window Access",
                detail: windowGranted
                    ? "Individual meeting apps and windows"
                    : WindowShareAccess.wasProbed
                        ? "Grant Screen Recording, then Enable again if this stays off."
                        : "Individual meeting apps and windows",
                granted: windowGranted,
                required: true,
                systemImage: "macwindow.on.rectangle"
            ),
            PermissionStatus(
                id: "mic",
                title: "Microphone",
                detail: "Your side of the conversation",
                granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                required: true,
                systemImage: "mic.fill"
            ),
            PermissionStatus(
                id: "speech",
                title: "Speech",
                detail: "On-device transcript only",
                granted: SFSpeechRecognizer.authorizationStatus() == .authorized,
                required: false,
                systemImage: "waveform"
            ),
            PermissionStatus(
                id: "notifications",
                title: "Notifications",
                detail: "Optional meeting alerts",
                granted: await notificationGranted(),
                required: false,
                systemImage: "bell.fill"
            ),
            PermissionStatus(
                id: "calendar",
                title: "Calendar",
                detail: "Optional meeting context",
                granted: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                required: false,
                systemImage: "calendar"
            )
        ]
    }

    static func request(_ id: String) async {
        await withForegroundActivation {
            switch id {
            case "screen":
                ScreenCaptureAccess.request()
            case "windows":
                await WindowShareAccess.request()
            case "mic":
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case "speech":
                await requestSpeechAuthorization()
                try? await TranscriptionEngine.ensureModel()
            case "notifications":
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            case "calendar":
                await requestCalendarAccess()
            default:
                break
            }
        }
    }

    /// Drop floating Sauron panels so System Settings / TCC dialogs can appear on top.
    static func demoteFloatingPanelsForSystemUI() {
        for window in NSApp.windows where window.isVisible && window.level >= .floating {
            window.level = .normal
        }
    }

    static func restoreFloatingUtilityPanels() {
        for window in NSApp.windows where window.isVisible {
            // Non-activating utility panels (transcript / assist) may float again.
            // Key panels (onboarding) stay at normal so System Settings stays on top.
            if window.styleMask.contains(.nonactivatingPanel) {
                window.level = .floating
            }
        }
    }

    private static func withForegroundActivation(_ work: () async -> Void) async {
        demoteFloatingPanelsForSystemUI()
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(80))
        await work()
        // Give System Settings / permission sheets time to order above us.
        try? await Task.sleep(for: .milliseconds(250))
        restoreFloatingUtilityPanels()
        // Stay .regular briefly if we were accessory — restoring too soon can
        // yank focus back under System Settings. Defer accessory restore.
        if previous == .accessory {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if NSApp.activationPolicy() == .regular,
                   NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                    // Another app (often System Settings) is frontmost — safe to go accessory.
                    NSApp.setActivationPolicy(.accessory)
                } else if NSApp.activationPolicy() == .regular {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        } else {
            NSApp.setActivationPolicy(previous)
        }
    }

    private static func openPrivacyPane(_ pane: String) {
        demoteFloatingPanelsForSystemUI()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ]
        for item in urls {
            if let url = URL(string: item) {
                NSWorkspace.shared.open(url)
                // Nudge Settings forward after launch.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    demoteFloatingPanelsForSystemUI()
                    if let settings = NSWorkspace.shared.runningApplications.first(where: {
                        let id = $0.bundleIdentifier ?? ""
                        return id.contains("SystemSettings")
                            || id.contains("systempreferences")
                            || id.contains("Preference")
                    }) {
                        settings.activate(options: [.activateIgnoringOtherApps])
                    }
                }
                return
            }
        }
    }

    nonisolated private static func requestSpeechAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    private static func requestCalendarAccess() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined, .writeOnly:
            let granted = await calendarClient.requestFullAccess()
            if !granted, EKEventStore.authorizationStatus(for: .event) != .notDetermined {
                openPrivacyPane("Privacy_Calendars")
            }
        default:
            openPrivacyPane("Privacy_Calendars")
        }
    }

    private static func notificationGranted() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
}

struct PermissionsOnboarding: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var permissions: [PermissionStatus] = []
    @State private var downloadingModel = false
    @State private var requestingID: String?
    @State private var modelError: String?
    @State private var confettiToken: UUID?
    @State private var didCelebrate = false

    var body: some View {
        ZStack {
            VStack(spacing: 18) {
                header
                VStack(spacing: 0) {
                    ForEach(Array(permissions.enumerated()), id: \.element.id) { index, item in
                        PermissionCard(
                            item: item,
                            isRequesting: requestingID == item.id
                        ) {
                            Task { await request(item) }
                        }
                        if index < permissions.count - 1 {
                            Divider()
                                .opacity(0.45)
                        }
                    }
                }
                footer
            }
            .padding(24)

            ConfettiCannonView(token: confettiToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .frame(width: GlassChrome.onboardingSize.width, height: GlassChrome.onboardingSize.height)
        .task { await prepare() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.fill")
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, options: .nonRepeating, value: confettiToken)
            Text("Sauron")
                .font(.title2.weight(.semibold))
            Text(headerCopy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var headerCopy: String {
        if permissions.allGranted {
            return "You're ready. Sauron can sit in the menu bar and capture meetings on this Mac."
        }
        return "Grant access so Sauron can sit in the menu bar and capture meetings on this Mac."
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if downloadingModel {
                ProgressView("Preparing speech…")
                    .controlSize(.small)
            }
            if let modelError {
                Text(modelError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(permissions.allGranted ? "Get Started" : "Continue", systemImage: "arrow.right") {
                appState.finishOnboarding()
            }
            .observerGlassProminentButton()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    private func request(_ item: PermissionStatus) async {
        requestingID = item.id
        await PermissionService.request(item.id)
        await apply(await PermissionService.snapshot())
        requestingID = nil
    }

    private func prepare() async {
        await apply(await PermissionService.snapshot())
        while !Task.isCancelled {
            let next = await PermissionService.snapshot()
            if next != permissions {
                await apply(next)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func apply(_ next: [PermissionStatus]) async {
        withAnimation(.smooth(duration: 0.35)) {
            permissions = next
        }
        celebrateIfComplete()
    }

    private func celebrateIfComplete() {
        guard permissions.allGranted, !didCelebrate else { return }
        didCelebrate = true
        guard !reduceMotion else { return }
        confettiToken = UUID()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

struct PermissionCard: View {
    let item: PermissionStatus
    var isRequesting = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.systemImage)
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            statusControl
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(item.granted ? .isSelected : [])
        .animation(.smooth(duration: 0.35), value: item.granted)
    }

    @ViewBuilder
    private var statusControl: some View {
        if item.granted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.green)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Granted")
        } else if isRequesting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 72, height: 28)
        } else {
            Button("Enable", action: action)
                .observerGlassButton()
                .controlSize(.regular)
        }
    }
}
