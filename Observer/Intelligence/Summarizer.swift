import Foundation

enum Summarizer {
    static func messages(transcript: String, meetingTitle: String, appName: String) -> [ChatMessage] {
        let system = ChatMessage(
            role: "system",
            content: """
            You are Observer, a local meeting assistant. Summarize the transcript.
            Return JSON only, no markdown fences, with this shape:
            {
              "title": "short meeting title",
              "summary": "1-3 paragraph recap",
              "decisions": ["..."],
              "actionItems": [{"owner": null, "text": "..."}],
              "openQuestions": ["..."],
              "quotes": ["short notable quotes"]
            }
            Speakers are labeled You and Others. If the transcript is thin, still return JSON and say so in summary.
            Never invent attendees or facts that are not in the transcript.
            """
        )
        let user = ChatMessage(
            role: "user",
            content: """
            Meeting window: \(meetingTitle)
            App: \(appName)

            Transcript:
            \(transcript.isEmpty ? "(No transcript was captured.)" : transcript)
            """
        )
        return [system, user]
    }

    static func parse(_ raw: String) -> MeetingSummary {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = extractJSON(from: trimmed),
           let parsed = try? JSONDecoder().decode(WireSummary.self, from: data) {
            return MeetingSummary(
                title: parsed.title,
                summary: parsed.summary,
                decisions: parsed.decisions ?? [],
                actionItems: (parsed.actionItems ?? []).map {
                    ActionItem(owner: $0.owner, text: $0.text)
                },
                openQuestions: parsed.openQuestions ?? [],
                quotes: parsed.quotes ?? [],
                rawText: trimmed
            )
        }
        return MeetingSummary(
            title: "Meeting notes",
            summary: trimmed,
            decisions: [],
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

    private struct WireSummary: Decodable {
        var title: String
        var summary: String
        var decisions: [String]?
        var actionItems: [WireAction]?
        var openQuestions: [String]?
        var quotes: [String]?
    }

    private struct WireAction: Decodable {
        var owner: String?
        var text: String
    }
}
