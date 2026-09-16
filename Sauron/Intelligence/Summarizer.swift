import Foundation

enum Summarizer {
    static func messages(
        transcript: String,
        meetingTitle: String,
        appName: String,
        meetingDate: Date,
        durationMinutes: Int,
        ownerDisplayName: String,
        ledger: [LiveItem],
        openItems: [TrackedItemReconciler.OpenItem],
        memoryContext: String? = nil,
        mcpToolHint: String? = nil
    ) -> [ChatMessage] {
        let system = ChatMessage(
            role: "system",
            content: SauronPrompts.system([
                SauronPrompts.Fragment.identity,
                """
                Task: turn a finished meeting transcript into complete, structured, auditable meeting notes. \
                Capture everything a participant would want to find later — not just the headline. \
                Be exhaustive on decisions, asks, action items, blockers, dates, and numbers; be concise in prose.
                """,
                SauronPrompts.Fragment.speakerConventions,
                SauronPrompts.Fragment.asksVsActions,
                SauronPrompts.Fragment.grounding,
                SauronPrompts.Fragment.confidenceScale,
                """
                Extraction rules:
                - Walk the transcript in order. For every ask, question, or blocker raised, decide by the END of the meeting whether it was closed. \
                Closed-in-meeting → resolvedInMeeting. Still open → actionItems (if accepted/assigned), asks (if not yet accepted, or declined/deferred), openQuestions, or blockers.
                - A commitment ("I'll do X") is an actionItem owned by the speaker.
                - Deduplicate: the same task mentioned three times is one actionItem with the most complete owner/due.
                - Decisions need agreement. Record the rationale when stated. If a decision was later reversed in the meeting, record only the final state and note the reversal in the rationale.
                - Segment the meeting into topics in the order discussed; each topic gets a 1–3 sentence summary.
                - Capture every date/deadline/follow-up meeting as a date object with an ISO date when derivable from context (meeting date is provided).
                - Capture every quantitative figure that carries meaning (budgets, counts, percentages, versions) as a metric.
                - Attendees: only people who spoke or were explicitly said to be present. Mark the owner. People merely mentioned go in entities.
                - Live-captured items (if provided) are hints from a real-time pass; verify each against the transcript, keep what holds, correct owners/dues, drop what does not.
                - Prior open items (if provided): if this meeting gives evidence about one — it was finished, is in progress, is blocked, was dropped, was reassigned, or was replaced by a new task — emit a priorItemUpdate with the item's id, the evidence, and a confidence. Do not emit an update if the item was not discussed. You may use memory tools to check the original context of an item if the match is unclear.
                - Past-meeting excerpts (if provided) are continuity context only; never lift content from them into this meeting's sections.
                - If the transcript is thin or empty, still return the full schema with empty arrays and explain in "quality.notes".
                """,
                SauronPrompts.Fragment.jsonContract,
                """
                Schema:
                {
                  "title": "short meeting title",
                  "meetingType": "standup|oneOnOne|planning|review|design|customer|interview|training|social|other",
                  "summary": "1–3 paragraphs: what happened, what was decided, what is now owed, why it matters",
                  "tldr": ["3–6 bullets a skimmer needs"],
                  "attendees": [{"name":"...","isOwner":false,"role":"as stated or null","org":"as stated or null"}],
                  "topics": [{"order":1,"title":"...","summary":"1–3 sentences","evidence":"..."}],
                  "decisions": [{"text":"...","rationale":"or null","madeBy":["..."],"evidence":"...","confidence":0.0}],
                  "actionItems": [{"text":"...","owner":"or null","requester":"or null","due":"verbatim or null","dueISO":"YYYY-MM-DD or null","evidence":"...","confidence":0.0}],
                  "asks": [{"text":"...","requester":"or null","target":"or null","status":"open|accepted|declined|deferred","evidence":"...","confidence":0.0}],
                  "resolvedInMeeting": [{"text":"...","kind":"ask|question|blocker|actionItem","resolution":"how it was closed","resolvedBy":"or null","evidence":"...","confidence":0.0}],
                  "openQuestions": [{"text":"...","askedBy":"or null","directedTo":"or null","evidence":"...","confidence":0.0}],
                  "blockers": [{"text":"...","blockedParty":"or null","unblockedBy":"what would unblock it, or null","severity":"low|medium|high","evidence":"...","confidence":0.0}],
                  "nextSteps": ["planned follow-ups that are not yet assigned tasks"],
                  "dates": [{"text":"...","isoDate":"YYYY-MM-DD or null","relatesTo":"decision/action text or null","evidence":"..."}],
                  "metrics": [{"text":"...","value":"...","unit":"or null","speaker":"or null","evidence":"..."}],
                  "entities": [{"name":"...","kind":"person|org|system|project|document","evidence":"..."}],
                  "priorItemUpdates": [{"trackedItemId":"uuid","status":"completed|inProgress|blocked|dropped|reassigned|superseded","newOwner":"or null","note":"...","evidence":"...","confidence":0.0}],
                  "quotes": [{"text":"verbatim ≤200 chars","speaker":"or null"}],
                  "sentiment": {"overall":"positive|neutral|tense|mixed","note":"one sentence or null"},
                  "quality": {"transcriptCoverage":"full|partial|thin|empty","notes":"speaker-label reliability, gaps, crosstalk, or null"}
                }
                """,
                mcpToolHint ?? ""
            ])
        )

        let dateString = Self.isoDateFormatter.string(from: meetingDate)

        let ledgerLines = ledger.map { item in
            "- [\(item.id)] \(item.type.rawValue) owner=\(item.owner ?? "null") due=\(item.due ?? "null"): \(item.text)"
        }.joined(separator: "\n")

        let openItemLines = openItems.map { item in
            let owner = item.owner ?? "null"
            let originDateString = Self.isoDateFormatter.string(from: item.originDate)
            return "- [\(item.id.uuidString)] \(item.kind) owner=\(owner) from=\"\(item.originMeetingTitle)\" (\(originDateString)): \(item.text)"
        }.joined(separator: "\n")

        var userBody = """
            Meeting: \(meetingTitle)
            App: \(appName)
            Date: \(dateString)   Duration: \(durationMinutes)m
            Owner: \(ownerDisplayName)

            Live-captured items during the meeting (hints; verify against transcript):
            \(ledgerLines.isEmpty ? "(none)" : ledgerLines)

            Open tracked items from prior meetings (emit priorItemUpdates only for ones discussed):
            \(openItemLines.isEmpty ? "(none)" : openItemLines)
            """
        if let memoryContext, !memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userBody += """


            Relevant excerpts from past meetings (continuity only):
            \(memoryContext)
            """
        }
        userBody += """


            Transcript:
            \(transcript.isEmpty ? "(No transcript was captured.)" : transcript)
            """
        let user = ChatMessage(role: "user", content: userBody)
        return [system, user]
    }

    static func parse(_ raw: String) -> MeetingSummary {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = extractJSON(from: trimmed),
           let parsed = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
            var summary = parsed
            summary.rawText = trimmed
            return summary
        }
        return MeetingSummary(
            title: "Meeting notes",
            summary: trimmed,
            actionItems: [],
            openQuestions: [],
            quotes: [],
            rawText: trimmed
        )
    }

    static func extractJSON(from raw: String) -> Data? {
        var text = raw
        if let fenced = raw.range(of: "```json") ?? raw.range(of: "```") {
            let after = raw[fenced.upperBound...]
            if let end = after.range(of: "```") {
                text = String(after[..<end.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
