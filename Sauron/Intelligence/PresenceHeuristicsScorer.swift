import Foundation

enum PresenceHeuristicsScorer {
    private static let thinSelfThreshold = 80

    static func messages(
        selfTranscript: String,
        fullTranscript: String,
        meetingTitle: String,
        meetingType: MeetingType
    ) -> [ChatMessage] {
        let trimmedSelf = selfTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let useFallback = trimmedSelf.count < thinSelfThreshold
        let body = useFallback
            ? fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedSelf

        let system = ChatMessage(
            role: "system",
            content: SauronPrompts.system([
                SauronPrompts.Fragment.identity,
                """
                Task: score how the meeting OWNER came across — not remote participants. This is private coaching for the owner; be candid, specific, and kind.
                """,
                SauronPrompts.Fragment.speakerConventions,
                SauronPrompts.Fragment.grounding,
                """
                Dimensions (1 weak – 10 excellent), evidence only from the owner's own lines:
                - likeability: warmth, rapport, constructive tone
                - professionalism: composure, respect, meeting etiquette
                - receptiveness: listening cues, acknowledging others, openness to pushback
                - clarity: concise, organized, easy to follow; low filler
                - collaboration: inviting input, building on others, shared problem-solving
                Rules:
                - Cite one short verbatim owner quote per dimension in "evidence" when available; null otherwise.
                - If owner evidence is thin, stay in 5–6 and set "evidenceLevel":"thin".
                - Estimate the owner's share of speaking (by characters) as talkShare 0.0–1.0 when the full transcript is provided; null otherwise.
                - Give exactly one strength and one concrete, actionable improvement.
                """,
                SauronPrompts.Fragment.jsonContract,
                """
                Schema:
                {
                  "likeability": 7, "professionalism": 8, "receptiveness": 6, "clarity": 7, "collaboration": 8,
                  "evidence": {"likeability":"...","professionalism":"...","receptiveness":"...","clarity":"...","collaboration":"..."},
                  "talkShare": 0.0,
                  "fillerNote": "e.g. frequent 'um'/'like', or null",
                  "strength": "one sentence",
                  "improvement": "one sentence, actionable",
                  "note": "one-sentence overall coaching summary",
                  "evidenceLevel": "solid|thin"
                }
                """
            ])
        )

        var userBody = """
            Meeting: \(meetingTitle)
            Meeting type: \(meetingType.rawValue)

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
        var evidence: [String: String] = [:]
        for (key, value) in wire.evidence ?? [:] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evidence[key] = value
        }
        return MeetingPresenceScores(
            likeability: wire.likeability,
            professionalism: wire.professionalism,
            receptiveness: wire.receptiveness,
            clarity: wire.clarity,
            collaboration: wire.collaboration,
            note: (note?.isEmpty == false) ? note : nil,
            scoredAt: .now,
            evidence: evidence,
            talkShare: wire.talkShare,
            fillerNote: wire.fillerNote,
            strength: wire.strength,
            improvement: wire.improvement,
            evidenceLevel: wire.evidenceLevel
        )
    }

    private struct WirePresence: Decodable {
        var likeability: Double
        var professionalism: Double
        var receptiveness: Double
        var clarity: Double
        var collaboration: Double
        var note: String?
        var evidence: [String: String]?
        var talkShare: Double?
        var fillerNote: String?
        var strength: String?
        var improvement: String?
        var evidenceLevel: String?
    }
}
