import Foundation
import SwiftData

enum SharedModel {
    static let container: ModelContainer = {
        MediaStore.migrateFromObserverIfNeeded()
        let schema = Schema([
            Meeting.self,
            TranscriptSegment.self,
            SpeakerProfile.self,
            TrackedItem.self
        ])
        let support = MediaStore.applicationSupport
        let storeURL = support.appending(path: "Sauron.store")
        let legacyStore = support.appending(path: "Observer.store")
        if !FileManager.default.fileExists(atPath: storeURL.path),
           FileManager.default.fileExists(atPath: legacyStore.path) {
            try? FileManager.default.moveItem(at: legacyStore, to: storeURL)
            for ext in ["store-shm", "store-wal"] {
                let old = support.appending(path: "Observer.\(ext)")
                let new = support.appending(path: "Sauron.\(ext)")
                if FileManager.default.fileExists(atPath: old.path) {
                    try? FileManager.default.moveItem(at: old, to: new)
                }
            }
        }
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Early 0.1.x: schema changes are not migrated — reset the store once.
            try? FileManager.default.removeItem(at: storeURL)
            let sidecar = storeURL.deletingPathExtension().appendingPathExtension("store-shm")
            let wal = storeURL.deletingPathExtension().appendingPathExtension("store-wal")
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.removeItem(at: wal)
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Failed to create Sauron store: \(error)")
            }
        }
    }()
}

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var appName: String
    var bundleIdentifier: String
    var title: String
    var windowTitle: String
    var kindRaw: String
    var recordVisual: Bool
    var recordAudio: Bool
    var recordTranscript: Bool
    var videoPath: String?
    var micAudioPath: String?
    var systemAudioPath: String?
    var mixedAudioPath: String?
    var summaryJSON: String?
    var assistCardsJSON: String?
    var memoryCitationsJSON: String?
    var presenceJSON: String?
    var userNotes: String?
    var memoryIndexedAt: Date?
    var statusRaw: String

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        appName: String,
        bundleIdentifier: String,
        title: String,
        windowTitle: String,
        kind: MeetingKind,
        recordVisual: Bool,
        recordAudio: Bool,
        recordTranscript: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowTitle = windowTitle
        self.kindRaw = kind.rawValue
        self.recordVisual = recordVisual
        self.recordAudio = recordAudio
        self.recordTranscript = recordTranscript
        self.statusRaw = MeetingRecordStatus.recording.rawValue
        self.segments = []
    }

    var kind: MeetingKind {
        MeetingKind(rawValue: kindRaw) ?? .unknown
    }

    var status: MeetingRecordStatus {
        get { MeetingRecordStatus(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }

    var selfTalkDuration: TimeInterval {
        MeetingTalkMetrics.selfTalkDuration(
            segments: segments.map { (isSelf: $0.isSelf, start: $0.start, end: $0.end) }
        )
    }

    var talkShare: Double {
        MeetingTalkMetrics.talkShare(selfTalk: selfTalkDuration, meetingDuration: duration)
    }

    var plainTranscript: String {
        segments
            .sorted { $0.start < $1.start }
            .map { "\(SpeakerKey.fallbackDisplayName($0.speakerKey)): \($0.text)" }
            .joined(separator: "\n")
    }

    @MainActor
    var namedTranscript: String {
        segments
            .sorted { $0.start < $1.start }
            .map { "\(SpeakerProfileStore.shared.displayName(for: $0.speakerKey)): \($0.text)" }
            .joined(separator: "\n")
    }

    var summary: MeetingSummary? {
        guard let summaryJSON, let data = summaryJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    var presence: MeetingPresenceScores? {
        get {
            guard let presenceJSON, let data = presenceJSON.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MeetingPresenceScores.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                presenceJSON = String(data: data, encoding: .utf8)
            } else {
                presenceJSON = nil
            }
        }
    }

    var assistCards: [LiveAssistCard] {
        get {
            guard let assistCardsJSON, let data = assistCardsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([LiveAssistCard].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                assistCardsJSON = String(data: data, encoding: .utf8)
            } else {
                assistCardsJSON = nil
            }
        }
    }

    var memoryCitations: [MemoryCitation] {
        get {
            guard let memoryCitationsJSON, let data = memoryCitationsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([MemoryCitation].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                memoryCitationsJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                memoryCitationsJSON = String(data: data, encoding: .utf8)
            }
        }
    }

    var playableVideoURL: URL? { existingMediaURL(videoPath) }
    var playableMicURL: URL? { existingMediaURL(micAudioPath) }
    var playableSystemURL: URL? { existingMediaURL(systemAudioPath) }
    var playableMixedURL: URL? { existingMediaURL(mixedAudioPath) }
    var hasPlayableMedia: Bool {
        playableVideoURL != nil
            || playableMixedURL != nil
            || playableMicURL != nil
            || playableSystemURL != nil
    }

    private func existingMediaURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else { return nil }
        return url
    }
}

enum MeetingRecordStatus: String, Codable, Sendable {
    case recording
    case processing
    case ready
    case failed
}

@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var speakerRaw: String
    var text: String
    var isFinal: Bool
    var meeting: Meeting?

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        speakerKey: String,
        text: String,
        isFinal: Bool,
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speakerRaw = SpeakerKey.normalize(speakerKey)
        self.text = text
        self.isFinal = isFinal
        self.meeting = meeting
    }

    var speakerKey: String {
        get { SpeakerKey.normalize(speakerRaw) }
        set { speakerRaw = SpeakerKey.normalize(newValue) }
    }

    var isSelf: Bool { SpeakerKey.isSelf(speakerKey) }
}

@Model
final class SpeakerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var isSelf: Bool
    var sortIndex: Int
    var accentRaw: String?
    var voiceprintJSON: String?

    init(
        id: UUID = UUID(),
        name: String,
        isSelf: Bool = false,
        sortIndex: Int = 0,
        accentRaw: String? = nil,
        voiceprintJSON: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
        self.sortIndex = sortIndex
        self.accentRaw = accentRaw
        self.voiceprintJSON = voiceprintJSON
    }

    var speakerKey: String {
        isSelf ? SpeakerKey.selfKey : SpeakerKey.profile(id)
    }

    var voiceprint: [Float] {
        get {
            guard let voiceprintJSON, let data = voiceprintJSON.data(using: .utf8),
                  let values = try? JSONDecoder().decode([Float].self, from: data)
            else { return [] }
            return values
        }
        set {
            if newValue.isEmpty {
                voiceprintJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                voiceprintJSON = String(data: data, encoding: .utf8)
            }
        }
    }
}

enum TrackedItemKind: String, Codable, Sendable, CaseIterable {
    case action
    case ask
    case blocker
    case nextStep

    var title: String {
        switch self {
        case .action: "Action"
        case .ask: "Ask"
        case .blocker: "Blocker"
        case .nextStep: "Next step"
        }
    }

    var systemImage: String {
        switch self {
        case .action: "checklist"
        case .ask: "questionmark.circle"
        case .blocker: "exclamationmark.triangle"
        case .nextStep: "arrow.right.circle"
        }
    }
}

enum TrackedItemStatus: String, Codable, Sendable {
    case open
    case done
    case dismissed
}

enum TrackedItemCompletedBy: String, Codable, Sendable {
    case manual
    case auto
}

@Model
final class TrackedItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var text: String
    var owner: String?
    var dueRaw: String?
    var statusRaw: String
    var sourceMeetingID: UUID
    var sourceMeetingTitle: String
    var createdAt: Date
    var completedAt: Date?
    var completedByRaw: String?
    var resolvedInMeetingID: UUID?
    var resolutionNote: String?
    var fingerprint: String

    init(
        id: UUID = UUID(),
        kind: TrackedItemKind,
        text: String,
        owner: String? = nil,
        dueRaw: String? = nil,
        status: TrackedItemStatus = .open,
        sourceMeetingID: UUID,
        sourceMeetingTitle: String,
        createdAt: Date = .now,
        fingerprint: String
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.text = text
        self.owner = owner
        self.dueRaw = dueRaw
        self.statusRaw = status.rawValue
        self.sourceMeetingID = sourceMeetingID
        self.sourceMeetingTitle = sourceMeetingTitle
        self.createdAt = createdAt
        self.fingerprint = fingerprint
    }

    var kind: TrackedItemKind {
        get { TrackedItemKind(rawValue: kindRaw) ?? .action }
        set { kindRaw = newValue.rawValue }
    }

    var status: TrackedItemStatus {
        get { TrackedItemStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    var completedBy: TrackedItemCompletedBy? {
        get {
            guard let completedByRaw else { return nil }
            return TrackedItemCompletedBy(rawValue: completedByRaw)
        }
        set { completedByRaw = newValue?.rawValue }
    }
}
