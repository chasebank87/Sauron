import Foundation

enum PresenceHeuristicsScorer {
    private static let thinSelfThreshold = 80

    static func messages(
        selfTranscript: String,
        fullTranscript: String,
        meetingTitle: String
    ) -> [ChatMessage] {
        let trimmedSelf = selfTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let useFallback = trimmedSelf.count < thinSelfThreshold
        let body = useFallback
            ? fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedSelf

        let system = ChatMessage(
            role: "system",
            content: """
            You are Sauron, scoring how the meeting OWNER spoke — not remote participants.
            Return JSON only, no markdown fences, with this shape:
            {
              "likeability": 7,
              "professionalism": 8,
              "receptiveness": 6,
              "clarity": 7,
              "collaboration": 8,
              "note": "one short coaching sentence"
            }
            Score each dimension from 1 (weak) to 10 (excellent) based only on the provided transcript.
            likeability: warmth, rapport, constructive tone
            professionalism: composure, respect, meeting etiquette
            receptiveness: listening cues, acknowledging others, openness to feedback
            clarity: concise, organized, easy-to-follow speech
            collaboration: inviting input, building on others, shared problem-solving
            Prefer evidence from the owner's lines. If evidence is thin, stay near the middle (5–6) and say so in note.
            Never invent quotes or events that are not in the transcript.
            """
        )

        var userBody = """
            Meeting: \(meetingTitle)

            """
        if useFallback {
            userBody += """
            Owner-only lines were sparse. Score the owner's presence from the full transcript; \
            speaker labels mark who spoke (self / named speakers / Speaker N).

            Full transcript:
            \(body.isEmpty ? "(No transcript was captured.)" : body)
            """
        } else {
            userBody += """
            Owner (self) transcript lines only:
            \(body)
            """
        }

        return [system, ChatMessage(role: "user", content: userBody)]
    }

    static func selfTranscript(from meeting: Meeting) -> String {
        meeting.segments
            .filter(\.isSelf)
            .sorted { $0.start < $1.start }
            .map(\.text)
            .joined(separator: "\n")
    }

    static func parse(_ raw: String) -> MeetingPresenceScores? {
        guard let data = Summarizer.extractJSON(from: raw),
              let wire = try? JSONDecoder().decode(WirePresence.self, from: data)
        else { return nil }
        let note = wire.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingPresenceScores(
            likeability: wire.likeability,
            professionalism: wire.professionalism,
            receptiveness: wire.receptiveness,
            clarity: wire.clarity,
            collaboration: wire.collaboration,
            note: (note?.isEmpty == false) ? note : nil,
            scoredAt: .now
        )
    }

    private struct WirePresence: Decodable {
        var likeability: Double
        var professionalism: Double
        var receptiveness: Double
        var clarity: Double
        var collaboration: Double
        var note: String?
    }
}
