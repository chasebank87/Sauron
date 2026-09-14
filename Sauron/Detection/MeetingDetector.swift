import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RecordedMeetingWatch {
    /// Seconds without any continuing meeting window before we auto-stop.
    /// Window IDs churn during screen share / layout changes — keep this generous.
    static let endGrace: TimeInterval = 12

    /// Exact original window/session still visible.
    static func isPresent(
        sessionKey: String,
        windowID: UInt32?,
        in matches: [MeetingCandidate]
    ) -> Bool {
        continuingMatch(
            sessionKey: sessionKey,
            windowID: windowID,
            bundleIdentifier: nil,
            kind: nil,
            in: matches
        ) != nil
    }

    /// Prefer the original window; otherwise another catalog-matched window of the
    /// same meeting app (Zoom/Teams often replace window IDs mid-call). Home/chrome
    /// windows are already filtered out by `MeetingAppCatalog`, so same-app matches
    /// are treated as the call continuing — not as a reason to keep recording forever
    /// after hang-up (hang-up leaves no catalog match).
    static func continuingMatch(
        sessionKey: String,
        windowID: UInt32?,
        bundleIdentifier: String?,
        kind: MeetingKind?,
        in matches: [MeetingCandidate]
    ) -> MeetingCandidate? {
        if let exact = matches.first(where: { $0.sessionKey == sessionKey }) {
            return exact
        }
        if let windowID, let exact = matches.first(where: { $0.windowID == windowID }) {
            return exact
        }
        guard let bundleIdentifier, let kind else { return nil }
        let peers = matches.filter {
            $0.bundleIdentifier == bundleIdentifier && $0.kind == kind
        }
        return MeetingWindowPicker.best(from: peers)
    }
}

@MainActor
@Observable
final class MeetingDetector {
    var candidate: MeetingCandidate?
    var lastError: String?
    private(set) var recordedMeetingEnded = false
    /// True while this Mac appears to be presenting into the live meeting.
    private(set) var isUserScreenSharing = false

    private var task: Task<Void, Never>?
    private var snoozedSessions: Set<String> = []
    private var mutedBundlesUntil: [String: Date] = [:]
    private var stableSince: [String: Date] = [:]
    private var missingSince: [String: Date] = [:]
    private var recordingWatch: MeetingCandidate?
    private var recordingMissingSince: Date?
    private var expiredPromptSessionKey: String?
    private var screenShareHold = ScreenShareHold()

    private let pollInterval: Duration = .milliseconds(750)
    /// How long a catalog-matched window must stay visible before prompting.
    /// Short enough to feel instant; long enough to ignore launch flicker.
    private let stability: TimeInterval = 1.25
    private let disappearance: TimeInterval = 15
    private let recordingPollInterval: Duration = .milliseconds(750)

    /// Returns subscribed calendar IDs (`nil` = all). Wired from Settings via AppState.
    var subscribedCalendarIDsProvider: (() -> [String]?)?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.scan()
                let delay: Duration
                if self.lastError == "Screen Recording is off" {
                    delay = .seconds(30)
                } else if self.recordingWatch != nil {
                    delay = self.recordingPollInterval
                } else {
                    delay = self.pollInterval
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func snoozeCurrent() {
        snooze(candidate)
    }

    func snooze(_ candidate: MeetingCandidate?) {
        guard let candidate else { return }
        snoozedSessions.insert(candidate.sessionKey)
        if self.candidate?.sessionKey == candidate.sessionKey {
            self.candidate = nil
        }
    }

    func muteAppToday() {
        muteApp(candidate)
    }

    func muteApp(_ candidate: MeetingCandidate?) {
        guard let candidate else { return }
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date().addingTimeInterval(86_400)
        mutedBundlesUntil[candidate.bundleIdentifier] = endOfDay
        snoozedSessions.insert(candidate.sessionKey)
        if self.candidate?.sessionKey == candidate.sessionKey {
            self.candidate = nil
        }
    }

    func watchRecording(_ candidate: MeetingCandidate) {
        recordedMeetingEnded = false
        recordingMissingSince = nil
        recordingWatch = candidate.isSimulated ? nil : candidate
    }

    func clearRecordingWatch() {
        recordingWatch = nil
        recordingMissingSince = nil
        recordedMeetingEnded = false
    }

    func consumeExpiredPromptSession() -> String? {
        let key = expiredPromptSessionKey
        expiredPromptSessionKey = nil
        return key
    }

    func clearCandidate() {
        candidate = nil
    }

    func forget(sessionKey: String) {
        snoozedSessions.remove(sessionKey)
        stableSince[sessionKey] = nil
        missingSince[sessionKey] = nil
    }

    private func scan() async {
        pruneMutes()
        guard ScreenCaptureAccess.granted() else {
            lastError = "Screen Recording is off"
            updateScreenShareWatch(windows: [])
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let matches = content.windows.compactMap(match(window:))
            lastError = nil
            updateScreenShareWatch(windows: content.windows)
            updateRecordingWatch(matches: matches)

            let presentKeys = Set(matches.map(\.sessionKey))
            for key in stableSince.keys where !presentKeys.contains(key) {
                missingSince[key] = missingSince[key] ?? Date()
                if let missing = missingSince[key], Date().timeIntervalSince(missing) >= disappearance {
                    stableSince[key] = nil
                    missingSince[key] = nil
                    snoozedSessions.remove(key)
                    if candidate?.sessionKey == key {
                        expiredPromptSessionKey = key
                        candidate = nil
                    }
                }
            }

            let eligible = matches.filter { match in
                if snoozedSessions.contains(match.sessionKey) { return false }
                if let until = mutedBundlesUntil[match.bundleIdentifier], until > Date() { return false }
                if stableSince[match.sessionKey] == nil {
                    stableSince[match.sessionKey] = Date()
                }
                guard let started = stableSince[match.sessionKey] else { return false }
                return Date().timeIntervalSince(started) >= stability
            }

            for match in matches {
                missingSince[match.sessionKey] = nil
            }

            if let best = MeetingWindowPicker.best(from: eligible) {
                var resolved = best
                if let calendar = CalendarSignal.currentMeeting(
                    subscribedCalendarIDs: subscribedCalendarIDsProvider?()
                ) {
                    resolved.calendarEventTitle = calendar.title
                }
                candidate = resolved
                return
            }
        } catch {
            lastError = error.localizedDescription
            updateScreenShareWatch(windows: [])
        }
    }

    private func updateScreenShareWatch(windows: [SCWindow]) {
        let scProbes = windows.map {
            LocalScreenShareSignal.WindowProbe(
                title: $0.title ?? "",
                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                appName: $0.owningApplication?.applicationName
            )
        }
        let detected = LocalScreenShareSignal.isShareDetected(
            windows: scProbes + cgWindowProbes(),
            runningApps: NSWorkspace.shared.runningApplications.map {
                (bundleIdentifier: $0.bundleIdentifier, appName: $0.localizedName)
            }
        )
        screenShareHold.update(detected: detected)
        isUserScreenSharing = screenShareHold.isSharing
    }

    private func cgWindowProbes() -> [LocalScreenShareSignal.WindowProbe] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return info.map { window in
            let title = window[kCGWindowName as String] as? String ?? ""
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let pid = cgWindowPID(window)
            let bundle = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            return LocalScreenShareSignal.WindowProbe(
                title: title,
                bundleIdentifier: bundle,
                appName: owner
            )
        }
    }

    private func cgWindowPID(_ window: [String: Any]) -> pid_t? {
        if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
            return pid
        }
        if let pid = window[kCGWindowOwnerPID as String] as? Int {
            return pid_t(pid)
        }
        return nil
    }

    private func updateRecordingWatch(matches: [MeetingCandidate]) {
        guard let watch = recordingWatch, !recordedMeetingEnded else { return }
        if let continuing = RecordedMeetingWatch.continuingMatch(
            sessionKey: watch.sessionKey,
            windowID: watch.windowID,
            bundleIdentifier: watch.bundleIdentifier,
            kind: watch.kind,
            in: matches
        ) {
            recordingMissingSince = nil
            // Retarget when Zoom/Teams swaps the live window mid-call.
            if continuing.sessionKey != watch.sessionKey {
                recordingWatch = continuing
            }
            return
        }
        let started = recordingMissingSince ?? Date()
        recordingMissingSince = started
        if Date().timeIntervalSince(started) >= RecordedMeetingWatch.endGrace {
            recordedMeetingEnded = true
        }
    }

    private func match(window: SCWindow) -> MeetingCandidate? {
        guard window.isOnScreen else { return nil }
        let frame = window.frame
        guard frame.width >= 220, frame.height >= 160 else { return nil }
        let title = window.title ?? ""
        let bundle = window.owningApplication?.bundleIdentifier
        let appName = window.owningApplication?.applicationName
        guard let kind = MeetingAppCatalog.match(
            bundleIdentifier: bundle,
            appName: appName,
            windowTitle: title
        ) else { return nil }

        let bundleID = bundle ?? "unknown"
        return MeetingCandidate(
            id: "\(bundleID):\(window.windowID)",
            kind: kind,
            appName: appName ?? kind.displayName,
            bundleIdentifier: bundleID,
            windowTitle: title,
            windowID: window.windowID,
            isSimulated: false,
            calendarEventTitle: nil,
            pixelArea: max(frame.width, 1) * max(frame.height, 1)
        )
    }

    private func pruneMutes() {
        let now = Date()
        mutedBundlesUntil = mutedBundlesUntil.filter { $0.value > now }
    }
}
