import Foundation
import SwiftData

@MainActor
enum MeetingStore {
    static func create(
        from candidate: MeetingCandidate,
        modes: Set<RecordMode>,
        context: ModelContext
    ) -> Meeting {
        let meeting = Meeting(
            appName: candidate.appName,
            bundleIdentifier: candidate.bundleIdentifier,
            title: candidate.displayName,
            windowTitle: candidate.windowTitle,
            kind: candidate.kind,
            recordVisual: modes.contains(.visual),
            recordAudio: modes.contains(.audio) || modes.contains(.transcript),
            recordTranscript: modes.contains(.transcript)
        )
        context.insert(meeting)
        try? context.save()
        return meeting
    }

    static func recent(limit: Int = 30, context: ModelContext) -> [Meeting] {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    static func all(context: ModelContext) -> [Meeting] {
        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func fetch(from start: Date, to end: Date, context: ModelContext) -> [Meeting] {
        let predicate = #Predicate<Meeting> { meeting in
            meeting.startedAt >= start && meeting.startedAt < end
        }
        let descriptor = FetchDescriptor<Meeting>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func meeting(id: UUID, context: ModelContext) -> Meeting? {
        let predicate = #Predicate<Meeting> { $0.id == id }
        var descriptor = FetchDescriptor<Meeting>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func persist(
        liveSegments: [LiveSegment],
        into meeting: Meeting,
        context: ModelContext
    ) {
        let existing = Dictionary(uniqueKeysWithValues: meeting.segments.map { ($0.id, $0) })
        for live in liveSegments where live.isFinal && !live.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let row = existing[live.id] {
                row.text = live.text
                row.end = live.end
                row.speakerKey = live.speakerKey
                row.isFinal = true
            } else {
                let segment = TranscriptSegment(
                    id: live.id,
                    start: live.start,
                    end: live.end,
                    speakerKey: live.speakerKey,
                    text: live.text,
                    isFinal: true,
                    meeting: meeting
                )
                context.insert(segment)
            }
        }
        try? context.save()
    }

    static func remapSpeaker(
        from sourceKey: String,
        to targetKey: String,
        in meeting: Meeting,
        context: ModelContext
    ) {
        let from = SpeakerKey.normalize(sourceKey)
        let to = SpeakerKey.normalize(targetKey)
        guard from != to else { return }
        for segment in meeting.segments where segment.speakerKey == from {
            segment.speakerKey = to
        }
        try? context.save()
    }

    /// Deletes meetings, cascading transcript segments, media folders, memory chunks, and linked asks.
    @discardableResult
    static func delete(_ meetings: [Meeting], context: ModelContext) -> Int {
        guard !meetings.isEmpty else { return 0 }
        let ids = meetings.map(\.id)
        TrackedItemStore.deleteLinked(to: Set(ids), context: context)
        TrackedItemProposalStore.deleteLinked(to: Set(ids), context: context)
        for meeting in meetings {
            let folder = MediaStore.meetingsRoot
                .appending(path: meeting.id.uuidString, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: folder)
            for path in [meeting.videoPath, meeting.micAudioPath, meeting.systemAudioPath, meeting.mixedAudioPath] {
                guard let path, !path.isEmpty else { continue }
                let url = URL(fileURLWithPath: path)
                if !url.path.hasPrefix(folder.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            MeetingMemoryStore.shared.remove(meetingID: meeting.id)
            context.delete(meeting)
        }
        try? context.save()
        return ids.count
    }

    @discardableResult
    static func delete(ids: Set<UUID>, context: ModelContext) -> Int {
        let meetings = ids.compactMap { meeting(id: $0, context: context) }
        return delete(meetings, context: context)
    }
}
