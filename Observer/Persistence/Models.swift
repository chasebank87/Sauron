import Foundation
import SwiftData

enum SharedModel {
    static let container: ModelContainer = {
        let schema = Schema([Meeting.self, TranscriptSegment.self])
        let storeURL = MediaStore.applicationSupport.appending(path: "Observer.store")
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create Observer store: \(error)")
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

    var plainTranscript: String {
        segments
            .sorted { $0.start < $1.start }
            .map { "\($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
    }

    var summary: MeetingSummary? {
        guard let summaryJSON, let data = summaryJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
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
        speaker: Speaker,
        text: String,
        isFinal: Bool,
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speakerRaw = speaker.rawValue
        self.text = text
        self.isFinal = isFinal
        self.meeting = meeting
    }

    var speaker: Speaker {
        Speaker(rawValue: speakerRaw) ?? .others
    }
}
