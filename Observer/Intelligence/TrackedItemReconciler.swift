import Foundation

enum TrackedItemReconciler {
    struct Resolution: Equatable, Sendable {
        var id: UUID
        var note: String
    }

    static func messages(
        openItems: [(id: UUID, kind: String, text: String, owner: String?)],
        meetingTitle: String,
        summaryText: String,
        transcript: String
    ) -> [ChatMessage] {
        let list = openItems.enumerated().map { index, item in
            let owner = item.owner.map { " owner=\($0)" } ?? ""
            return "\(index + 1). id=\(item.id.uuidString) kind=\(item.kind)\(owner) text=\(item.text)"
        }.joined(separator: "\n")

        let system = ChatMessage(
            role: "system",
            content: """
            You reconcile open action items and questions against a new meeting.
            Return JSON only: {"resolved":[{"id":"<uuid>","note":"short evidence from this meeting"}]}
            Only include an item when the new meeting clearly shows it is done or answered.
            Prefer precision over recall. If unsure, omit it. Never invent resolutions.
            """
        )
        let user = ChatMessage(
            role: "user",
            content: """
            New meeting: \(meetingTitle)

            Summary:
            \(summaryText)

            Transcript excerpt:
            \(transcript.isEmpty ? "(empty)" : String(transcript.prefix(12_000)))

            Open items:
            \(list.isEmpty ? "(none)" : list)
            """
        )
        return [system, user]
    }

    static func parse(_ raw: String) -> [Resolution] {
        guard let data = Summarizer.extractJSON(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resolved = json["resolved"] as? [[String: Any]]
        else { return [] }
        return resolved.compactMap { item in
            guard let idString = item["id"] as? String,
                  let id = UUID(uuidString: idString)
            else { return nil }
            let note = (item["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Resolution(id: id, note: note)
        }
    }
}
