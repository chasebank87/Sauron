import Foundation

enum Summarizer {
    static func messages(
        transcript: String,
        meetingTitle: String,
        appName: String,
        memoryContext: String? = nil,
        mcpToolHint: String? = nil
    ) -> [ChatMessage] {
        var systemContent = """
            You are Sauron, a local meeting assistant. Summarize the transcript into structured meeting notes.
            Return JSON only, no markdown fences, with this shape:
            {
              "title": "short meeting title",
              "summary": "1-3 paragraph recap of what happened and why it matters",
              "notes": ["notable discussion points or context worth remembering"],
              "keyPeople": ["names of people who spoke or were clearly referenced"],
              "topics": ["main topics covered"],
              "decisions": ["decisions that were made"],
              "actionItems": [{"owner": "Name or null", "text": "concrete task", "due": "date/time if mentioned, else null"}],
              "nextSteps": ["planned follow-ups that are not yet assigned tasks"],
              "blockers": ["risks, blockers, or dependencies called out"],
              "openQuestions": ["unresolved questions"],
              "quotes": ["short notable quotes"]
            }
            Speakers are labeled by name in the transcript (for example "Chase:" or "Speaker 2:").
            Prefer real names for keyPeople and action-item owners when the transcript provides them.
            If the transcript is thin, still return JSON and say so in summary; use empty arrays when needed.
            Never invent attendees, decisions, or facts that are not in the transcript.
            When past-meeting excerpts are provided, you may use them only for continuity context; do not invent beyond the transcript and those excerpts.
            """
        if let mcpToolHint, !mcpToolHint.isEmpty {
            systemContent += "\n\n\(mcpToolHint)"
        }
        let system = ChatMessage(
            role: "system",
            content: systemContent
        )
        var userBody = """
            Meeting window: \(meetingTitle)
            App: \(appName)

            Transcript:
            \(transcript.isEmpty ? "(No transcript was captured.)" : transcript)
            """
        if let memoryContext, !memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userBody += """


            Relevant excerpts from past meetings (do not invent beyond these):
            \(memoryContext)
            """
        }
        let user = ChatMessage(role: "user", content: userBody)
        return [system, user]
    }

    static func parse(_ raw: String) -> MeetingSummary {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = extractJSON(from: trimmed),
           let parsed = try? JSONDecoder().decode(WireSummary.self, from: data) {
            return MeetingSummary(
                title: parsed.title,
                summary: parsed.summary,
                notes: parsed.notes ?? [],
                keyPeople: parsed.keyPeople ?? [],
                topics: parsed.topics ?? [],
                decisions: parsed.decisions ?? [],
                actionItems: (parsed.actionItems ?? []).map {
                    ActionItem(owner: $0.owner, text: $0.text, due: $0.due)
                },
                nextSteps: parsed.nextSteps ?? [],
                blockers: parsed.blockers ?? [],
                openQuestions: parsed.openQuestions ?? [],
                quotes: parsed.quotes ?? [],
                rawText: trimmed
            )
        }
        return MeetingSummary(
            title: "Meeting notes",
            summary: trimmed,
            notes: [],
            keyPeople: [],
            topics: [],
            decisions: [],
            actionItems: [],
            nextSteps: [],
            blockers: [],
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

    private struct WireSummary: Decodable {
        var title: String
        var summary: String
        var notes: [String]?
        var keyPeople: [String]?
        var topics: [String]?
        var decisions: [String]?
        var actionItems: [WireAction]?
        var nextSteps: [String]?
        var blockers: [String]?
        var openQuestions: [String]?
        var quotes: [String]?
    }

    private struct WireAction: Decodable {
        var owner: String?
        var text: String
        var due: String?
    }
}
