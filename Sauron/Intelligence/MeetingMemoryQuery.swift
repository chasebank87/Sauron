import Foundation
import SwiftData

/// Structured read models for memory RAG (prompt injection + MCP tools).
struct MemoryMeetingListItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var kind: String
    var durationSeconds: Double
    var hasSummary: Bool
    var memoryIndexed: Bool
}

struct MemoryMeetingDetail: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var kind: String
    var appName: String
    var durationSeconds: Double
    var summaryTitle: String?
    var summary: String?
    var notes: [String]
    var decisions: [String]
    var actionItems: [String]
    var asks: [String]
    var topics: [String]
    var openQuestions: [String]
    var transcriptExcerpt: String
    var memoryIndexedAt: Date?
}

struct MemoryIndexStatus: Codable, Equatable, Sendable {
    var memoryEnabled: Bool
    var chunkCount: Int
    var meetingCount: Int
    var lastRebuild: Date?
    var embeddingModelID: String
    var embeddingProvider: String
}

enum MemoryQueryError: Error, LocalizedError, Equatable {
    case memoryDisabled
    case meetingNotFound
    case emptyQuery
    case embeddingFailed(String)

    var errorDescription: String? {
        switch self {
        case .memoryDisabled:
            "Meeting memory is disabled in Sauron settings."
        case .meetingNotFound:
            "No meeting found for that id."
        case .emptyQuery:
            "Query must not be empty."
        case .embeddingFailed(let message):
            "Embedding failed: \(message)"
        }
    }
}

enum MeetingMemoryQuery {
    @MainActor
    static func status(appState: AppState) -> MemoryIndexStatus {
        MemoryIndexStatus(
            memoryEnabled: appState.settings.memoryEnabled,
            chunkCount: MeetingMemoryStore.shared.chunkCount,
            meetingCount: MeetingMemoryStore.shared.meetingIDs().count,
            lastRebuild: MeetingMemoryStore.shared.lastRebuild,
            embeddingModelID: appState.settings.resolvedEmbeddingModelID,
            embeddingProvider: appState.settings.resolvedEmbeddingProviderKind.rawValue
        )
    }

    @MainActor
    static func listRecent(limit: Int = 10, context: ModelContext) -> [MemoryMeetingListItem] {
        let capped = max(1, min(limit, 50))
        return MeetingStore.recent(limit: capped, context: context).map { meeting in
            MemoryMeetingListItem(
                id: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt,
                kind: meeting.kind.rawValue,
                durationSeconds: meeting.duration,
                hasSummary: meeting.summary != nil,
                memoryIndexed: meeting.memoryIndexedAt != nil
            )
        }
    }

    @MainActor
    static func meetingDetail(id: UUID, context: ModelContext, transcriptLimit: Int = 4_000) throws -> MemoryMeetingDetail {
        guard let meeting = MeetingStore.meeting(id: id, context: context) else {
            throw MemoryQueryError.meetingNotFound
        }
        let summary = meeting.summary
        let transcript = meeting.namedTranscript
        let excerpt: String
        if transcript.count <= transcriptLimit {
            excerpt = transcript
        } else {
            excerpt = String(transcript.prefix(transcriptLimit)) + "\n…"
        }
        return MemoryMeetingDetail(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            kind: meeting.kind.rawValue,
            appName: meeting.appName,
            durationSeconds: meeting.duration,
            summaryTitle: summary?.title,
            summary: summary?.summary,
            notes: summary?.notes ?? [],
            decisions: (summary?.decisions ?? []).map(\.text),
            actionItems: (summary?.actionItems ?? []).map(\.text),
            asks: (summary?.asks ?? []).map(\.text),
            topics: (summary?.topics ?? []).map(\.title),
            openQuestions: (summary?.openQuestions ?? []).map(\.text),
            transcriptExcerpt: excerpt,
            memoryIndexedAt: meeting.memoryIndexedAt
        )
    }
}
