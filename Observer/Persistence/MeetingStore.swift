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
                row.isFinal = true
            } else {
                let segment = TranscriptSegment(
                    id: live.id,
                    start: live.start,
                    end: live.end,
                    speaker: live.speaker,
                    text: live.text,
                    isFinal: true,
                    meeting: meeting
                )
                context.insert(segment)
            }
        }
        try? context.save()
    }
}
