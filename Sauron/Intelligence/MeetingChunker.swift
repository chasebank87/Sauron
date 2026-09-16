import Foundation

enum MemoryChunkKind: String, Codable, Sendable {
    case summary
    case notes
    case decision
    case action
    case transcript
    case topic
    case ask
    case blocker
    case resolved
    case document
    case userNote
}

struct MemoryChunk: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var kind: MemoryChunkKind
    var text: String
    var start: TimeInterval?
    var end: TimeInterval?
    var embedding: [Float]
}

enum MeetingChunker {
    private static let documentWindowSize = 1000
    private static let documentOverlap = 150

    static func chunks(
        meetingID: UUID,
        title: String,
        date: Date,
        transcriptSegments: [(start: TimeInterval, end: TimeInterval, text: String)],
        summary: MeetingSummary?,
        documents: [(name: String, text: String)] = [],
        userNotes: String? = nil
    ) -> [MemoryChunk] {
        var result: [MemoryChunk] = []

        if let summary {
            appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .summary, text: summary.summary)
            for note in summary.notes {
                appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .notes, text: note)
            }
            for topic in summary.topics {
                let text = topic.summary.isEmpty ? topic.title : "\(topic.title): \(topic.summary)"
                appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .topic, text: text)
            }
            for decision in summary.decisions {
                let rationale = decision.rationale.map { " (\($0))" } ?? ""
                appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .decision, text: "\(decision.text)\(rationale)")
            }
            for action in summary.actionItems {
                let owner = action.owner.map { " (\($0))" } ?? ""
                appendBlock(
                    &result,
                    meetingID: meetingID,
                    title: title,
                    date: date,
                    kind: .action,
                    text: "\(action.text)\(owner)"
                )
            }
            for ask in summary.asks {
                appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .ask, text: "\(ask.text) (\(ask.status.rawValue))")
            }
            for question in summary.openQuestions {
                appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .ask, text: question.text)
            }
            for blocker in summary.blockers {
                appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .blocker, text: "\(blocker.text) (\(blocker.severity.rawValue))")
            }
            for resolved in summary.resolvedInMeeting {
                appendBlock(&result, meetingID: meetingID, title: title, date: date, kind: .resolved, text: "\(resolved.text) → \(resolved.resolution)")
            }
        }

        if let userNotes {
            let trimmed = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendBlock(
                    &result,
                    meetingID: meetingID,
                    title: title,
                    date: date,
                    kind: .userNote,
                    text: "Your notes:\n\(trimmed)"
                )
            }
        }

        let windowSize = 10
        let overlap = 2
        let cleaned = transcriptSegments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !cleaned.isEmpty {
            var index = 0
            while index < cleaned.count {
                let end = min(index + windowSize, cleaned.count)
                let slice = Array(cleaned[index..<end])
                let text = slice.map(\.text).joined(separator: "\n")
                if text.count >= 40 {
                    result.append(
                        MemoryChunk(
                            id: UUID(),
                            meetingID: meetingID,
                            meetingTitle: title,
                            meetingDate: date,
                            kind: .transcript,
                            text: text,
                            start: slice.first?.start,
                            end: slice.last?.end,
                            embedding: []
                        )
                    )
                }
                if end >= cleaned.count { break }
                index = max(index + windowSize - overlap, index + 1)
            }
        }

        result.append(contentsOf: documentChunks(
            meetingID: meetingID,
            title: title,
            date: date,
            documents: documents
        ))
        return result
    }

    static func documentChunks(
        meetingID: UUID,
        title: String,
        date: Date,
        documents: [(name: String, text: String)]
    ) -> [MemoryChunk] {
        var result: [MemoryChunk] = []
        for document in documents {
            let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let label = name.isEmpty ? "Document" : name
            let windows = characterWindows(body, size: documentWindowSize, overlap: documentOverlap)
            for window in windows {
                appendBlock(
                    &result,
                    meetingID: meetingID,
                    title: title,
                    date: date,
                    kind: .document,
                    text: "Document: \(label)\n\(window)"
                )
            }
        }
        return result
    }

    private static func characterWindows(_ text: String, size: Int, overlap: Int) -> [String] {
        guard size > 0 else { return [text] }
        if text.count <= size { return [text] }
        var windows: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            windows.append(String(text[start..<end]))
            if end >= text.endIndex { break }
            let advance = max(size - overlap, 1)
            guard let next = text.index(start, offsetBy: advance, limitedBy: text.endIndex) else { break }
            if next == start { break }
            start = next
        }
        return windows
    }

    private static func appendBlock(
        _ result: inout [MemoryChunk],
        meetingID: UUID,
        title: String,
        date: Date,
        kind: MemoryChunkKind,
        text: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        result.append(
            MemoryChunk(
                id: UUID(),
                meetingID: meetingID,
                meetingTitle: title,
                meetingDate: date,
                kind: kind,
                text: trimmed,
                start: nil,
                end: nil,
                embedding: []
            )
        )
    }
}
