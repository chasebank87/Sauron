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

    /// Syncs the still-open parts of a fresh summary into `TrackedItem`s. `resolvedInMeeting`
    /// items are deliberately excluded — they were raised and closed within this same meeting,
    /// so they never become an open tracked item (see SauronPrompts asksVsActions fragment).
    static func sync(from summary: MeetingSummary, meeting: Meeting, context: ModelContext) {
        var drafts: [(kind: TrackedItemKind, text: String, owner: String?, due: String?, timestamp: TimeInterval?)] = []
        for action in summary.actionItems {
            drafts.append((.action, action.text, action.owner, action.due, action.timestamp))
        }
        for ask in summary.asks where ask.status == .open || ask.status == .deferred {
            drafts.append((.ask, ask.text, ask.target, nil, ask.timestamp))
        }
        for question in summary.openQuestions {
            drafts.append((.ask, question.text, nil, nil, question.timestamp))
        }
        for blocker in summary.blockers {
            drafts.append((.blocker, blocker.text, blocker.blockedParty, nil, blocker.timestamp))
        }
        for step in summary.nextSteps {
            drafts.append((.nextStep, step, nil, nil, nil))
        }

        let existing = all(context: context)
        let byFingerprint = Dictionary(uniqueKeysWithValues: existing.map { ($0.fingerprint, $0) })

        for draft in drafts {
            let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fp = fingerprint(kind: draft.kind, text: trimmed, owner: draft.owner)
            if let item = byFingerprint[fp] {
                if item.status == .open {
                    item.text = trimmed
                    item.owner = draft.owner
                    item.dueRaw = draft.due
                    item.sourceMeetingTitle = meeting.title
                    if let timestamp = draft.timestamp { item.timestamp = timestamp }
                }
                continue
            }
            let item = TrackedItem(
                kind: draft.kind,
                text: trimmed,
                owner: draft.owner,
                dueRaw: draft.due,
                sourceMeetingID: meeting.id,
                sourceMeetingTitle: meeting.title,
                createdAt: meeting.startedAt,
                fingerprint: fp,
                timestamp: draft.timestamp
            )
            context.insert(item)
        }
        try? context.save()
    }

    @discardableResult
    static func create(
        kind: TrackedItemKind,
        text: String,
        owner: String? = nil,
        dueRaw: String? = nil,
        sourceMeetingID: UUID,
        sourceMeetingTitle: String,
        context: ModelContext
    ) -> TrackedItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fp = fingerprint(kind: kind, text: trimmed, owner: owner)
        if let existing = all(context: context).first(where: { $0.fingerprint == fp && $0.status == .open }) {
            return existing
        }
        let item = TrackedItem(
            kind: kind,
            text: trimmed,
            owner: owner,
            dueRaw: dueRaw,
            sourceMeetingID: sourceMeetingID,
            sourceMeetingTitle: sourceMeetingTitle,
            fingerprint: fp
        )
        context.insert(item)
        try? context.save()
        return item
    }

    static func update(
        _ item: TrackedItem,
        kind: TrackedItemKind? = nil,
        text: String? = nil,
        owner: String?? = nil,
        dueRaw: String?? = nil,
        context: ModelContext
    ) {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let kind { item.kind = kind }
        if let trimmedText, !trimmedText.isEmpty { item.text = trimmedText }
        if let owner { item.owner = owner }
        if let dueRaw { item.dueRaw = dueRaw }
        item.fingerprint = fingerprint(kind: item.kind, text: item.text, owner: item.owner)
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

    static func dismiss(_ item: TrackedItem, by: TrackedItemCompletedBy = .manual, context: ModelContext) {
        item.status = .dismissed
        item.completedAt = .now
        item.completedBy = by
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
