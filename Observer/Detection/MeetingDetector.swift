import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RecordedMeetingWatch {
    /// Seconds the watched meeting window must stay gone before we auto-stop.
    static let endGrace: TimeInterval = 4

    /// Only the original meeting window/session counts — leftover Zoom/Teams home UI must not keep recording alive.
    static func isPresent(
        sessionKey: String,
        windowID: UInt32?,
        in matches: [MeetingCandidate]
    ) -> Bool {
        matches.contains { match in
            if match.sessionKey == sessionKey { return true }
            if let windowID, match.windowID == windowID { return true }
            return false
        }
    }
}

@MainActor
@Observable
final class MeetingDetector {
    var candidate: MeetingCandidate?
    var lastError: String?
    private(set) var recordedMeetingEnded = false

    private var task: Task<Void, Never>?
    private var snoozedSessions: Set<String> = []
    private var mutedBundlesUntil: [String: Date] = [:]
    private var stableSince: [String: Date] = [:]
    private var missingSince: [String: Date] = [:]
    private var recordingWatch: MeetingCandidate?
    private var recordingMissingSince: Date?
    private var expiredPromptSessionKey: String?

    private let pollInterval: Duration = .seconds(2)
    private let stability: TimeInterval = 8
    private let disappearance: TimeInterval = 15
    private let recordingPollInterval: Duration = .seconds(1)

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
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let matches = content.windows.compactMap(match(window:))
            lastError = nil
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

            for match in matches {
                missingSince[match.sessionKey] = nil
                if snoozedSessions.contains(match.sessionKey) { continue }
                if let until = mutedBundlesUntil[match.bundleIdentifier], until > Date() { continue }

                if stableSince[match.sessionKey] == nil {
                    stableSince[match.sessionKey] = Date()
                }
                if let started = stableSince[match.sessionKey],
                   Date().timeIntervalSince(started) >= stability {
                    var resolved = match
                    if let calendar = CalendarSignal.currentMeeting() {
                        resolved.calendarEventTitle = calendar.title
                    }
                    candidate = resolved
                    return
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateRecordingWatch(matches: [MeetingCandidate]) {
        guard let watch = recordingWatch, !recordedMeetingEnded else { return }
        if RecordedMeetingWatch.isPresent(
            sessionKey: watch.sessionKey,
            windowID: watch.windowID,
            in: matches
        ) {
            recordingMissingSince = nil
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
            calendarEventTitle: nil
        )
    }

    private func pruneMutes() {
        let now = Date()
        mutedBundlesUntil = mutedBundlesUntil.filter { $0.value > now }
    }
}
