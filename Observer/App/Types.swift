import Foundation

enum AppStatus: Equatable, Sendable {
    case idle
    case detecting
    case prompt
    case recording
    case processing
}

enum PostMeetingPhase: Equatable, Sendable {
    case idle
    case savingCapture
    case mixingAudio
    case summarizing

    var title: String {
        switch self {
        case .idle: ""
        case .savingCapture: "Saving recording…"
        case .mixingAudio: "Mixing audio…"
        case .summarizing: "Writing summary…"
        }
    }

    var progress: Double {
        switch self {
        case .idle: 0
        case .savingCapture: 0.2
        case .mixingAudio: 0.45
        case .summarizing: 0.75
        }
    }
}

enum CaptureMedia: String, CaseIterable, Identifiable, Codable, Sendable {
    case videoAndAudio
    case audioOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoAndAudio: "Video and audio"
        case .audioOnly: "Audio only"
        }
    }

    var subtitle: String {
        switch self {
        case .videoAndAudio: "Meeting window plus mic and system audio"
        case .audioOnly: "Mic and system audio, no video"
        }
    }

    var systemImage: String {
        switch self {
        case .videoAndAudio: "video.fill"
        case .audioOnly: "waveform"
        }
    }

    var recordModes: Set<RecordMode> {
        switch self {
        case .videoAndAudio: [.visual, .audio]
        case .audioOnly: [.audio]
        }
    }

    func modes(transcript: Bool) -> Set<RecordMode> {
        var modes = recordModes
        if transcript { modes.insert(.transcript) }
        return modes
    }
}

enum CaptureAudioSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case meetingApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System audio"
        case .meetingApp: "Meeting app only"
        }
    }

    var settingTitle: String { "Meeting app only" }

    var settingDetail: String {
        switch self {
        case .system: "Capture all Mac audio (default)"
        case .meetingApp: "Only audio from the meeting app"
        }
    }

    var liveLabel: String {
        switch self {
        case .system: "System"
        case .meetingApp: "App"
        }
    }
}

enum AudioSignalSource: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case system
    case meetingApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .system: "System audio"
        case .meetingApp: "Meeting app audio"
        }
    }

    var shortTitle: String {
        switch self {
        case .microphone: "Mic"
        case .system: "System"
        case .meetingApp: "App"
        }
    }

    var silentMessage: String {
        switch self {
        case .microphone: "Nothing heard from your microphone"
        case .system: "Nothing heard from system audio"
        case .meetingApp: "Nothing heard from the meeting app"
        }
    }
}

enum RecordMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case visual
    case audio
    case transcript

    var id: String { rawValue }
}

enum Speaker: String, Codable, Sendable, CaseIterable {
    case you
    case others

    var displayName: String {
        switch self {
        case .you: "You"
        case .others: "Others"
        }
    }
}

enum MeetingKind: String, Codable, Sendable, Equatable {
    case zoom
    case teams
    case meet
    case faceTime
    case webex
    case slack
    case simulated
    case unknown

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .meet: "Google Meet"
        case .faceTime: "FaceTime"
        case .webex: "Webex"
        case .slack: "Slack"
        case .simulated: "Simulated"
        case .unknown: "Meeting"
        }
    }

    var systemImage: String {
        switch self {
        case .zoom: "video.fill"
        case .teams: "person.3.fill"
        case .meet: "video.badge.waveform.fill"
        case .faceTime: "video.fill"
        case .webex: "web.camera.fill"
        case .slack: "bubble.left.and.bubble.right.fill"
        case .simulated: "sparkles"
        case .unknown: "calendar.badge.clock"
        }
    }
}

struct MeetingCandidate: Equatable, Sendable, Identifiable {
    var id: String
    var kind: MeetingKind
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String
    var windowID: UInt32?
    var isSimulated: Bool
    var calendarEventTitle: String?

    var displayName: String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return kind.displayName }
        return trimmed
    }

    var sessionKey: String {
        if let windowID {
            return "\(bundleIdentifier):\(windowID)"
        }
        return "\(bundleIdentifier):\(windowTitle)"
    }

    func isSameMeeting(as other: MeetingCandidate) -> Bool {
        sessionKey == other.sessionKey || (bundleIdentifier == other.bundleIdentifier && kind == other.kind)
    }

    static func simulated() -> MeetingCandidate {
        MeetingCandidate(
            id: "simulate",
            kind: .simulated,
            appName: "Observer",
            bundleIdentifier: "app.observer.simulate",
            windowTitle: "Simulated meeting",
            windowID: nil,
            isSimulated: true,
            calendarEventTitle: nil
        )
    }
}

struct LiveSegment: Identifiable, Equatable, Sendable {
    var id: UUID
    var speaker: Speaker
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var isFinal: Bool
}

struct ActionItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var owner: String?
    var text: String
}

struct MeetingSummary: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var quotes: [String]
    var rawText: String?

    static let empty = MeetingSummary(
        title: "",
        summary: "",
        decisions: [],
        actionItems: [],
        openQuestions: [],
        quotes: [],
        rawText: nil
    )
}

enum ObserverError: LocalizedError {
    case screenRecordingDenied
    case microphoneDenied
    case speechUnavailable
    case noDisplay
    case captureFailed(String)
    case transcriptionFailed(String)
    case providerUnreachable(String)
    case missingAPIKey
    case summarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "Screen Recording is off. Enable Observer in System Settings → Privacy & Security → Screen Recording."
        case .microphoneDenied:
            "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
        case .speechUnavailable:
            "On-device speech is unavailable for this language. Download the speech model in Observer settings."
        case .noDisplay:
            "Observer could not find a display to capture."
        case .captureFailed(let message):
            "Recording failed: \(message)"
        case .transcriptionFailed(let message):
            "Transcription failed: \(message)"
        case .providerUnreachable(let name):
            "Could not reach \(name). Is it running?"
        case .missingAPIKey:
            "Add an API key in Settings to use this provider."
        case .summarizationFailed(let message):
            "Summary failed: \(message)"
        }
    }
}
