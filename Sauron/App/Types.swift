import CoreGraphics
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
    case enhancingTranscript
    case mixingAudio
    case composingVideo
    case summarizing

    var title: String {
        switch self {
        case .idle: ""
        case .savingCapture: "Saving recording…"
        case .enhancingTranscript: "Enhancing transcript…"
        case .mixingAudio: "Mixing audio…"
        case .composingVideo: "Combining video and audio…"
        case .summarizing: "Writing summary…"
        }
    }

    var progress: Double {
        switch self {
        case .idle: 0
        case .savingCapture: 0.12
        case .enhancingTranscript: 0.28
        case .mixingAudio: 0.42
        case .composingVideo: 0.58
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

enum RecordingResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case hd
    case uhd4K

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .hd: "HD (1080p)"
        case .uhd4K: "4K (2160p)"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: "Native resolution of the captured window or display"
        case .hd: "Caps capture at 1920×1080 — smaller files"
        case .uhd4K: "Caps capture at 3840×2160 — sharper, larger files"
        }
    }

    /// Longest-edge cap in pixels; `nil` means use CaptureEngine's default safety ceiling.
    var maxLongEdge: CGFloat? {
        switch self {
        case .auto: nil
        case .hd: 1920
        case .uhd4K: 3840
        }
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

/// Where video comes from when recording starts.
enum CaptureVideoTarget: Hashable, Sendable, Identifiable {
    /// Re-pick the best meeting window at start (today’s behavior).
    case auto
    case window(UInt32)
    case display(CGDirectDisplayID)

    var id: String {
        switch self {
        case .auto: "auto"
        case .window(let id): "window:\(id)"
        case .display(let id): "display:\(id)"
        }
    }
}

struct CaptureTargetOption: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var systemImage: String
    var target: CaptureVideoTarget
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

    static func remoteSilentMessage(kind: MeetingKind?, source: CaptureAudioSource) -> String {
        if kind?.needsCoreAudioSystemTap == true {
            return "Waiting for FaceTime call audio… Grant System Audio permission if prompted."
        }
        return source == .meetingApp
            ? AudioSignalSource.meetingApp.silentMessage
            : AudioSignalSource.system.silentMessage
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

    /// FaceTime / Continuity call audio is produced by system daemons (`avconferenced`),
    /// which ScreenCaptureKit cannot hear. Use a Core Audio process tap instead.
    var needsCoreAudioSystemTap: Bool {
        self == .faceTime
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
            appName: "Sauron",
            bundleIdentifier: "app.sauron.simulate",
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
    /// Wall-clock moment this row last changed — used to keep live scroll on the active speaker.
    var updatedAt: TimeInterval

    var isSelf: Bool { SpeakerKey.isSelf(speakerKey) }

    init(
        id: UUID,
        speakerKey: String,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool,
        updatedAt: TimeInterval = 0
    ) {
        self.id = id
        self.speakerKey = SpeakerKey.normalize(speakerKey)
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
        self.updatedAt = updatedAt
    }

    init(
        id: UUID,
        speaker: Speaker,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool,
        updatedAt: TimeInterval = 0
    ) {
        self.init(
            id: id,
            speakerKey: speaker.speakerKey,
            text: text,
            start: start,
            end: end,
            isFinal: isFinal,
            updatedAt: updatedAt
        )
    }
}

// `ActionItem` and the rest of the meeting-structure taxonomy (Decision, Ask, Blocker, Topic, …)
// live in Sauron/Models/MeetingStructure.swift, shared with the live extractor's vocabulary.

struct MeetingSummary: Codable, Equatable, Sendable {
    var title: String
    var meetingType: MeetingType
    var summary: String
    var tldr: [String]
    var attendees: [Attendee]
    var topics: [Topic]
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var asks: [Ask]
    var resolvedInMeeting: [ResolvedInMeetingItem]
    var openQuestions: [OpenQuestion]
    var blockers: [Blocker]
    var nextSteps: [String]
    var dates: [KeyDate]
    var metrics: [Metric]
    var entities: [Entity]
    var priorItemUpdates: [PriorItemUpdate]
    var quotes: [Quote]
    var sentiment: MeetingSentiment?
    var quality: MeetingQuality?
    var rawText: String?

    /// Legacy display alias: pre-refactor summaries stored free-form bullets as `notes`; the new
    /// schema captures the same idea as `tldr`. Kept so `ReportWindow`/`DashboardLibraryTab` don't
    /// need to know about the schema change.
    var notes: [String] { tldr }

    /// Legacy display alias: derived from `attendees` so `ReportWindow`/`DashboardLibraryTab`'s
    /// existing `[String]`-typed reads keep working unchanged.
    var keyPeople: [String] { attendees.map(\.name) }

    static let empty = MeetingSummary(
        title: "",
        meetingType: .other,
        summary: "",
        tldr: [],
        attendees: [],
        topics: [],
        decisions: [],
        actionItems: [],
        asks: [],
        resolvedInMeeting: [],
        openQuestions: [],
        blockers: [],
        nextSteps: [],
        dates: [],
        metrics: [],
        entities: [],
        priorItemUpdates: [],
        quotes: [],
        sentiment: nil,
        quality: nil,
        rawText: nil
    )

    enum CodingKeys: String, CodingKey {
        case title, meetingType, summary, tldr, attendees, topics, decisions
        case actionItems, asks, resolvedInMeeting, openQuestions, blockers, nextSteps
        case dates, metrics, entities, priorItemUpdates, quotes, sentiment, quality, rawText
    }

    /// Legacy keys this schema replaced (`notes` → `tldr`, `keyPeople` → `attendees`), read only
    /// when the new keys are absent so meetings summarized before this refactor still display.
    private enum LegacyCodingKeys: String, CodingKey { case notes, keyPeople }

    init(
        title: String,
        meetingType: MeetingType = .other,
        summary: String,
        tldr: [String] = [],
        attendees: [Attendee] = [],
        topics: [Topic] = [],
        decisions: [Decision] = [],
        actionItems: [ActionItem],
        asks: [Ask] = [],
        resolvedInMeeting: [ResolvedInMeetingItem] = [],
        openQuestions: [OpenQuestion],
        blockers: [Blocker] = [],
        nextSteps: [String] = [],
        dates: [KeyDate] = [],
        metrics: [Metric] = [],
        entities: [Entity] = [],
        priorItemUpdates: [PriorItemUpdate] = [],
        quotes: [Quote],
        sentiment: MeetingSentiment? = nil,
        quality: MeetingQuality? = nil,
        rawText: String? = nil
    ) {
        self.title = title
        self.meetingType = meetingType
        self.summary = summary
        self.tldr = tldr
        self.attendees = attendees
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.asks = asks
        self.resolvedInMeeting = resolvedInMeeting
        self.openQuestions = openQuestions
        self.blockers = blockers
        self.nextSteps = nextSteps
        self.dates = dates
        self.metrics = metrics
        self.entities = entities
        self.priorItemUpdates = priorItemUpdates
        self.quotes = quotes
        self.sentiment = sentiment
        self.quality = quality
        self.rawText = rawText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        meetingType = try container.decodeIfPresent(MeetingType.self, forKey: .meetingType) ?? .other
        summary = try container.decode(String.self, forKey: .summary)
        topics = try container.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        decisions = try container.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        asks = try container.decodeIfPresent([Ask].self, forKey: .asks) ?? []
        resolvedInMeeting = try container.decodeIfPresent([ResolvedInMeetingItem].self, forKey: .resolvedInMeeting) ?? []
        openQuestions = try container.decodeIfPresent([OpenQuestion].self, forKey: .openQuestions) ?? []
        blockers = try container.decodeIfPresent([Blocker].self, forKey: .blockers) ?? []
        nextSteps = try container.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        dates = try container.decodeIfPresent([KeyDate].self, forKey: .dates) ?? []
        metrics = try container.decodeIfPresent([Metric].self, forKey: .metrics) ?? []
        entities = try container.decodeIfPresent([Entity].self, forKey: .entities) ?? []
        priorItemUpdates = try container.decodeIfPresent([PriorItemUpdate].self, forKey: .priorItemUpdates) ?? []
        quotes = try container.decodeIfPresent([Quote].self, forKey: .quotes) ?? []
        sentiment = try container.decodeIfPresent(MeetingSentiment.self, forKey: .sentiment)
        quality = try container.decodeIfPresent(MeetingQuality.self, forKey: .quality)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)

        let legacyContainer = try? decoder.container(keyedBy: LegacyCodingKeys.self)
        var tldr = try container.decodeIfPresent([String].self, forKey: .tldr) ?? []
        if tldr.isEmpty, let legacyContainer, let legacyNotes = try? legacyContainer.decodeIfPresent([String].self, forKey: .notes) {
            tldr = legacyNotes
        }
        self.tldr = tldr

        var attendees = try container.decodeIfPresent([Attendee].self, forKey: .attendees) ?? []
        if attendees.isEmpty, let legacyContainer, let legacyPeople = try? legacyContainer.decodeIfPresent([String].self, forKey: .keyPeople) {
            attendees = legacyPeople.map { Attendee(name: $0) }
        }
        self.attendees = attendees
    }
}

struct MeetingPresenceScores: Codable, Equatable, Sendable {
    var likeability: Double
    var professionalism: Double
    var receptiveness: Double
    var clarity: Double
    var collaboration: Double
    var note: String?
    var scoredAt: Date
    var evidence: [String: String]
    var talkShare: Double?
    var fillerNote: String?
    var strength: String?
    var improvement: String?
    var evidenceLevel: String?

    enum CodingKeys: String, CodingKey {
        case likeability, professionalism, receptiveness, clarity, collaboration, note, scoredAt
        case evidence, talkShare, fillerNote, strength, improvement, evidenceLevel
    }

    init(
        likeability: Double,
        professionalism: Double,
        receptiveness: Double,
        clarity: Double,
        collaboration: Double,
        note: String? = nil,
        scoredAt: Date = .now,
        evidence: [String: String] = [:],
        talkShare: Double? = nil,
        fillerNote: String? = nil,
        strength: String? = nil,
        improvement: String? = nil,
        evidenceLevel: String? = nil
    ) {
        self.likeability = Self.clamp(likeability)
        self.professionalism = Self.clamp(professionalism)
        self.receptiveness = Self.clamp(receptiveness)
        self.clarity = Self.clamp(clarity)
        self.collaboration = Self.clamp(collaboration)
        self.note = note
        self.scoredAt = scoredAt
        self.evidence = evidence
        self.talkShare = talkShare
        self.fillerNote = fillerNote
        self.strength = strength
        self.improvement = improvement
        self.evidenceLevel = evidenceLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        likeability = Self.clamp(try container.decode(Double.self, forKey: .likeability))
        professionalism = Self.clamp(try container.decode(Double.self, forKey: .professionalism))
        receptiveness = Self.clamp(try container.decode(Double.self, forKey: .receptiveness))
        clarity = Self.clamp(try container.decode(Double.self, forKey: .clarity))
        collaboration = Self.clamp(try container.decode(Double.self, forKey: .collaboration))
        note = try container.decodeIfPresent(String.self, forKey: .note)
        scoredAt = try container.decodeIfPresent(Date.self, forKey: .scoredAt) ?? .now
        evidence = try container.decodeIfPresent([String: String].self, forKey: .evidence) ?? [:]
        talkShare = try container.decodeIfPresent(Double.self, forKey: .talkShare)
        fillerNote = try container.decodeIfPresent(String.self, forKey: .fillerNote)
        strength = try container.decodeIfPresent(String.self, forKey: .strength)
        improvement = try container.decodeIfPresent(String.self, forKey: .improvement)
        evidenceLevel = try container.decodeIfPresent(String.self, forKey: .evidenceLevel)
    }

    var average: Double {
        (likeability + professionalism + receptiveness + clarity + collaboration) / 5
    }

    static func clamp(_ value: Double) -> Double {
        min(10, max(1, value))
    }
}

enum PresenceDimension: String, CaseIterable, Identifiable, Sendable {
    case likeability
    case professionalism
    case receptiveness
    case clarity
    case collaboration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .likeability: "Likeability"
        case .professionalism: "Professionalism"
        case .receptiveness: "Receptiveness"
        case .clarity: "Clarity"
        case .collaboration: "Collaboration"
        }
    }

    func value(in scores: MeetingPresenceScores) -> Double {
        switch self {
        case .likeability: scores.likeability
        case .professionalism: scores.professionalism
        case .receptiveness: scores.receptiveness
        case .clarity: scores.clarity
        case .collaboration: scores.collaboration
        }
    }
}

enum MeetingTalkMetrics {
    static func selfTalkDuration(
        segments: [(isSelf: Bool, start: TimeInterval, end: TimeInterval)]
    ) -> TimeInterval {
        segments.reduce(0) { partial, segment in
            guard segment.isSelf else { return partial }
            return partial + max(0, segment.end - segment.start)
        }
    }

    static func talkShare(selfTalk: TimeInterval, meetingDuration: TimeInterval) -> Double {
        guard meetingDuration > 0 else { return 0 }
        return min(1, max(0, selfTalk / meetingDuration))
    }
}

enum SauronError: LocalizedError {
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
            "Screen Recording is off. Enable Sauron in System Settings → Privacy & Security → Screen Recording."
        case .microphoneDenied:
            "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
        case .speechUnavailable:
            "On-device speech is unavailable for this language. Download the speech model in Sauron settings."
        case .noDisplay:
            "Sauron could not find a display to capture."
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
