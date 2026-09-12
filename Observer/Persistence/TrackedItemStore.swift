import Foundation
import SwiftData

@MainActor
enum TrackedItemStore {
    nonisolated static func fingerprint(kind: TrackedItemKind, text: String, owner: String?) -> String {
        let normalizedText = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let ownerPart = (owner ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(kind.rawValue)|\(ownerPart)|\(normalizedText)"
    }

    static func sync(from summary: MeetingSummary, meeting: Meeting, context: ModelContext) {
        var drafts: [(TrackedItemKind, String, String?, String?)] = []
        for action in summary.actionItems {
            drafts.append((.action, action.text, action.owner, action.due))
        }
        for ask in summary.openQuestions {
            drafts.append((.ask, ask, nil, nil))
        }
        for blocker in summary.blockers {
            drafts.append((.blocker, blocker, nil, nil))
        }
        for step in summary.nextSteps {
            drafts.append((.nextStep, step, nil, nil))
        }

        let existing = all(context: context)
        let byFingerprint = Dictionary(uniqueKeysWithValues: existing.map { ($0.fingerprint, $0) })

        for draft in drafts {
            let trimmed = draft.1.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fp = fingerprint(kind: draft.0, text: trimmed, owner: draft.2)
            if let item = byFingerprint[fp] {
                if item.status == .open {
                    item.text = trimmed
                    item.owner = draft.2
                    item.dueRaw = draft.3
                    item.sourceMeetingTitle = meeting.title
                }
                continue
            }
            let item = TrackedItem(
                kind: draft.0,
                text: trimmed,
                owner: draft.2,
                dueRaw: draft.3,
                sourceMeetingID: meeting.id,
                sourceMeetingTitle: meeting.title,
                createdAt: meeting.startedAt,
                fingerprint: fp
            )
            context.insert(item)
        }
        try? context.save()
    }

    static func all(context: ModelContext) -> [TrackedItem] {
        let descriptor = FetchDescriptor<TrackedItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func openItems(context: ModelContext, limit: Int = 50) -> [TrackedItem] {
        all(context: context)
            .filter { $0.status == .open }
            .prefix(limit)
            .map { $0 }
    }

    static func complete(
        _ item: TrackedItem,
        by: TrackedItemCompletedBy,
        resolvedInMeetingID: UUID? = nil,
        note: String? = nil,
        context: ModelContext
    ) {
        item.status = .done
        item.completedAt = .now
        item.completedBy = by
        item.resolvedInMeetingID = resolvedInMeetingID
        item.resolutionNote = note
        try? context.save()
    }

    static func reopen(_ item: TrackedItem, context: ModelContext) {
        item.status = .open
        item.completedAt = nil
        item.completedBy = nil
        item.resolvedInMeetingID = nil
        item.resolutionNote = nil
        try? context.save()
    }

    static func dismiss(_ item: TrackedItem, context: ModelContext) {
        item.status = .dismissed
        item.completedAt = .now
        item.completedBy = .manual
        try? context.save()
    }

    static func deleteLinked(to meetingIDs: Set<UUID>, context: ModelContext) {
        guard !meetingIDs.isEmpty else { return }
        for item in all(context: context) {
            if meetingIDs.contains(item.sourceMeetingID)
                || (item.resolvedInMeetingID.map { meetingIDs.contains($0) } ?? false) {
                context.delete(item)
            }
        }
        try? context.save()
    }
}
