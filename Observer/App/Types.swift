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
    case composingVideo
    case summarizing

    var title: String {
        switch self {
        case .idle: ""
        case .savingCapture: "Saving recording…"
        case .mixingAudio: "Mixing audio…"
        case .composingVideo: "Combining video and audio…"
        case .summarizing: "Writing summary…"
        }
    }

    var progress: Double {
        switch self {
        case .idle: 0
        case .savingCapture: 0.15
        case .mixingAudio: 0.35
        case .composingVideo: 0.55
        case .summarizing: 0.8
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

    /// Lane → speaker key before diarization remaps remote turns.
    var speakerKey: String {
        switch self {
        case .you: SpeakerKey.selfKey
        case .others: SpeakerKey.cluster(1)
        }
    }
}

/// Stable identity for transcript rows: `self`, `cluster:N`, or `profile:<uuid>`.
enum SpeakerKey {
    static let selfKey = "self"

    static func cluster(_ index: Int) -> String { "cluster:\(max(1, index))" }

    static func profile(_ id: UUID) -> String { "profile:\(id.uuidString.lowercased())" }

    static func normalize(_ raw: String) -> String {
        switch raw {
        case "you", selfKey: return selfKey
        case "others": return cluster(1)
        default: return raw
        }
    }

    static func isSelf(_ key: String) -> Bool {
        let normalized = normalize(key)
        return normalized == selfKey
    }

    static func clusterIndex(_ key: String) -> Int? {
        let normalized = normalize(key)
        guard normalized.hasPrefix("cluster:") else { return nil }
        return Int(normalized.dropFirst("cluster:".count))
    }

    static func profileID(_ key: String) -> UUID? {
        let normalized = normalize(key)
        guard normalized.hasPrefix("profile:") else { return nil }
        return UUID(uuidString: String(normalized.dropFirst("profile:".count)))
    }

    static func fallbackDisplayName(_ key: String) -> String {
        let normalized = normalize(key)
        if isSelf(normalized) { return "You" }
        if let index = clusterIndex(normalized) { return "Speaker \(index)" }
        if let id = profileID(normalized) { return "Person \(id.uuidString.prefix(4))" }
        return normalized
    }
}

struct LiveAssistSource: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var url: String
}

enum LiveAssistKind: String, Codable, Sendable, CaseIterable {
    case insight
    case factCheck
    case research
    case memory

    var title: String {
        switch self {
        case .insight: "Insight"
        case .factCheck: "Fact-check"
        case .research: "Research"
        case .memory: "From past meetings"
        }
    }

    var systemImage: String {
        switch self {
        case .insight: "lightbulb"
        case .factCheck: "checkmark.shield"
        case .research: "globe"
        case .memory: "clock.arrow.circlepath"
        }
    }
}

enum FactCheckVerdict: String, Codable, Sendable {
    case supported
    case contested
    case unclear

    var title: String {
        switch self {
        case .supported: "Supported"
        case .contested: "Contested"
        case .unclear: "Unclear"
        }
    }
}

struct LiveAssistCard: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var kind: LiveAssistKind
    var title: String
    var body: String
    var sources: [LiveAssistSource] = []
    var verdict: FactCheckVerdict?
    var speakerKey: String?
    var createdAt: Date = .now
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
    /// On-screen area in points² — used to prefer the active meeting stage.
    var pixelArea: CGFloat = 0

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
            calendarEventTitle: nil,
            pixelArea: 1_280 * 720
        )
    }
}

struct LiveSegment: Identifiable, Equatable, Sendable {
    var id: UUID
    var speakerKey: String
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var isFinal: Bool

    var isSelf: Bool { SpeakerKey.isSelf(speakerKey) }

    init(
        id: UUID,
        speakerKey: String,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool
    ) {
        self.id = id
        self.speakerKey = SpeakerKey.normalize(speakerKey)
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }

    init(
        id: UUID,
        speaker: Speaker,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool
    ) {
        self.init(
            id: id,
            speakerKey: speaker.speakerKey,
            text: text,
            start: start,
            end: end,
            isFinal: isFinal
        )
    }
}

struct ActionItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var owner: String?
    var text: String
    var due: String?

    init(id: UUID = UUID(), owner: String? = nil, text: String, due: String? = nil) {
        self.id = id
        self.owner = owner
        self.text = text
        self.due = due
    }

    enum CodingKeys: String, CodingKey { case id, owner, text, due }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        text = try container.decode(String.self, forKey: .text)
        due = try container.decodeIfPresent(String.self, forKey: .due)
    }
}

struct MeetingSummary: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var notes: [String]
    var keyPeople: [String]
    var topics: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var nextSteps: [String]
    var blockers: [String]
    var openQuestions: [String]
    var quotes: [String]
    var rawText: String?

    static let empty = MeetingSummary(
        title: "",
        summary: "",
        notes: [],
        keyPeople: [],
        topics: [],
        decisions: [],
        actionItems: [],
        nextSteps: [],
        blockers: [],
        openQuestions: [],
        quotes: [],
        rawText: nil
    )

    enum CodingKeys: String, CodingKey {
        case title, summary, notes, keyPeople, topics, decisions
        case actionItems, nextSteps, blockers, openQuestions, quotes, rawText
    }

    init(
        title: String,
        summary: String,
        notes: [String] = [],
        keyPeople: [String] = [],
        topics: [String] = [],
        decisions: [String],
        actionItems: [ActionItem],
        nextSteps: [String] = [],
        blockers: [String] = [],
        openQuestions: [String],
        quotes: [String],
        rawText: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.notes = notes
        self.keyPeople = keyPeople
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.nextSteps = nextSteps
        self.blockers = blockers
        self.openQuestions = openQuestions
        self.quotes = quotes
        self.rawText = rawText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        keyPeople = try container.decodeIfPresent([String].self, forKey: .keyPeople) ?? []
        topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        nextSteps = try container.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        quotes = try container.decodeIfPresent([String].self, forKey: .quotes) ?? []
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
    }
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
