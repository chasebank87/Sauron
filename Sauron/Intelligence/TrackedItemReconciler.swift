import Foundation

/// Two-tier verifier: reconciles OPEN tracked items carried over from earlier meetings against a
/// new meeting's transcript + the summarizer's own hints (`priorItemUpdates`/`resolvedInMeeting`).
/// Only strong, verified evidence is eligible for automatic closure — everything else becomes a
/// `TrackedItemProposal` for the user (or the `resolve_tracked_item_proposal` MCP tool) to confirm.
/// See Sauron/App/AppState.swift `reconcileTrackedItems` for how `updates` gets applied.
enum TrackedItemReconciler {
    struct OpenItem {
        var id: UUID
        var kind: String
        var owner: String?
        var text: String
        var originMeetingTitle: String
        var originMeetingID: UUID
        var originDate: Date
    }

    struct Update: Equatable, Sendable {
        var id: UUID
        var status: PriorItemStatus
        var verification: TrackedItemVerification
        var confidence: Double
        var autoApply: Bool
        var note: String
        var evidence: String
        var newOwner: String?
        var supersededByText: String?
    }

    struct Result {
        var updates: [Update]
        var unmatchedHints: [String]
    }

    static func messages(
        openItems: [OpenItem],
        meetingTitle: String,
        meetingDate: Date,
        summaryText: String,
        priorItemUpdates: [PriorItemUpdate],
        resolvedInMeeting: [ResolvedInMeetingItem],
        transcript: String,
        memoryEnabled: Bool
    ) -> [ChatMessage] {
        let dateString = Self.isoDateFormatter.string(from: meetingDate)

        let system = ChatMessage(
            role: "system",
            content: SauronPrompts.system([
                SauronPrompts.Fragment.identity,
                """
                Task: reconcile OPEN tracked items (action items, asks, open questions, blockers) carried over from earlier meetings against a NEW meeting. \
                Decide, per item, whether this meeting provides evidence that its status changed, and how strong that evidence is.
                """,
                SauronPrompts.Fragment.speakerConventions,
                SauronPrompts.Fragment.grounding,
                """
                Matching rules:
                - Items are often rephrased. Match on intent, deliverable, and owner — not exact wording. "Send the budget deck" and "the finance slides went out" can be the same item if owner and context align.
                - If two open items could both match, choose the one whose owner and origin meeting fit best; if still ambiguous, emit both with lower confidence and verification="inferred".
                - If unsure what an item originally meant, call get_meeting on its origin meeting (id provided) before deciding. Budget: at most 4 memory calls total.

                Status values:
                - completed: the deliverable was done or the question answered.
                - inProgress: explicitly said to be underway, not done.
                - blocked: explicitly blocked; include what is blocking.
                - dropped: explicitly cancelled or no longer needed.
                - reassigned: a different owner now has it (set newOwner).
                - superseded: replaced by a new, different task in this meeting (set supersededByText).

                Verification tiers (set "verification"):
                - transcriptExplicit: the owner or another participant states it plainly ("I sent that", "that's done", "we answered that last week and X confirmed") AND nobody contradicts it in this meeting.
                - corroborated: the statement is indirect but a memory lookup or a second transcript passage confirms it (e.g. the deliverable is discussed as an existing thing).
                - inferred: reasonable but not stated; e.g. the topic moved on as if done.

                Decision policy:
                - Only completed/dropped with verification transcriptExplicit or corroborated and confidence ≥ 0.8 are eligible for automatic closure ("autoApply": true).
                - Everything else is a proposal ("autoApply": false) for the user to confirm.
                - Precision over recall. Omit items with no evidence in this meeting. Never invent resolutions.
                """,
                SauronPrompts.Fragment.confidenceScale,
                SauronPrompts.Fragment.jsonContract,
                """
                Schema:
                {
                  "updates": [
                    {
                      "id": "uuid of the tracked item",
                      "status": "completed|inProgress|blocked|dropped|reassigned|superseded",
                      "verification": "transcriptExplicit|corroborated|inferred",
                      "confidence": 0.0,
                      "autoApply": false,
                      "note": "one sentence explaining the evidence",
                      "evidence": "verbatim transcript snippet ≤160 chars",
                      "newOwner": "or null",
                      "supersededByText": "or null",
                      "sources": [{"kind":"meeting","id":"...","title":"...","date":"..."}]
                    }
                  ],
                  "unmatchedHints": ["summarizer hints you could not map to any open item, if any"]
                }
                """,
                memoryEnabled ? SauronPrompts.ToolAddon.memory : SauronPrompts.ToolAddon.noTools
            ])
        )

        let updateLines = priorItemUpdates.map { hint in
            "- id=\(hint.trackedItemId?.uuidString ?? "unknown") status=\(hint.status.rawValue) conf=\(hint.confidence): \(hint.note) | evidence: \(hint.evidence)"
        }.joined(separator: "\n")

        let resolvedLines = resolvedInMeeting.map { item in
            "- \(item.kind.rawValue): \(item.text) → \(item.resolution)"
        }.joined(separator: "\n")

        let openLines = openItems.enumerated().map { index, item in
            let owner = item.owner.map { " owner=\($0)" } ?? ""
            let originDateString = Self.isoDateFormatter.string(from: item.originDate)
            return "\(index + 1). id=\(item.id.uuidString) kind=\(item.kind)\(owner) origin=\"\(item.originMeetingTitle)\" originId=\(item.originMeetingID.uuidString) (\(originDateString)) text=\(item.text)"
        }.joined(separator: "\n")

        let user = ChatMessage(
            role: "user",
            content: """
            New meeting: \(meetingTitle)  (\(dateString))

            Summary:
            \(summaryText)

            Summarizer hints — priorItemUpdates:
            \(updateLines.isEmpty ? "(none)" : updateLines)

            Summarizer hints — resolvedInMeeting (may correspond to an older open item):
            \(resolvedLines.isEmpty ? "(none)" : resolvedLines)

            Open items:
            \(openLines.isEmpty ? "(none)" : openLines)

            Transcript excerpt (≤12,000 chars):
            \(transcript.isEmpty ? "(empty)" : String(transcript.prefix(12_000)))
            """
        )
        return [system, user]
    }

    static func parse(_ raw: String) -> Result {
        guard let data = Summarizer.extractJSON(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Result(updates: [], unmatchedHints: []) }

        let updates: [Update] = (json["updates"] as? [[String: Any]] ?? []).compactMap { item in
            guard let idString = item["id"] as? String, let id = UUID(uuidString: idString),
                  let statusRaw = item["status"] as? String, let status = PriorItemStatus(rawValue: statusRaw)
            else { return nil }
            let verification = (item["verification"] as? String).flatMap(TrackedItemVerification.init(rawValue:)) ?? .inferred
            let confidence = (item["confidence"] as? NSNumber)?.doubleValue ?? 0
            let autoApply = (item["autoApply"] as? NSNumber)?.boolValue ?? (item["autoApply"] as? Bool) ?? false
            let note = (item["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let evidence = (item["evidence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Update(
                id: id,
                status: status,
                verification: verification,
                confidence: confidence,
                autoApply: autoApply,
                note: note,
                evidence: evidence,
                newOwner: item["newOwner"] as? String,
                supersededByText: item["supersededByText"] as? String
            )
        }
        let unmatchedHints = (json["unmatchedHints"] as? [String]) ?? []
        return Result(updates: updates, unmatchedHints: unmatchedHints)
    }

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
