import Foundation

enum MeetingMemoryIndexer {
    @MainActor
    static func retrieveHits(
        query: String,
        appState: AppState,
        excludingMeetingID: UUID? = nil,
        topK: Int? = nil,
        minScore: Float? = nil
    ) async throws -> [MemoryHit] {
        guard appState.settings.memoryEnabled else {
            throw MemoryQueryError.memoryDisabled
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryQueryError.emptyQuery
        }
        do {
            let (client, _) = try appState.makeClient()
            let model = appState.settings.resolvedEmbeddingModelID
            let vectors = try await client.embed(model: model, texts: [trimmed])
            guard let queryVector = vectors.first else {
                throw MemoryQueryError.embeddingFailed("Provider returned no embedding vector.")
            }
            let limit = max(1, min(topK ?? appState.settings.memoryTopK, 24))
            let floor = minScore ?? 0.35
            var hits = MeetingMemoryStore.shared.search(
                queryEmbedding: queryVector,
                limit: limit,
                floor: floor
            )
            if let excludingMeetingID {
                hits = hits.filter { $0.chunk.meetingID != excludingMeetingID }
            }
            return hits
        } catch let error as MemoryQueryError {
            throw error
        } catch {
            throw MemoryQueryError.embeddingFailed(error.localizedDescription)
        }
    }

    @MainActor
    static func retrieveContext(
        query: String,
        appState: AppState,
        excludingMeetingID: UUID? = nil
    ) async -> (context: String, citations: [MemoryCitation]) {
        do {
            let hits = try await retrieveHits(
                query: query,
                appState: appState,
                excludingMeetingID: excludingMeetingID
            )
            return (MeetingMemoryStore.formatContext(hits), hits.map(MemoryCitation.init(hit:)))
        } catch {
            return ("", [])
        }
    }

    @MainActor
    static func index(meeting: Meeting, appState: AppState) async {
        guard appState.settings.memoryEnabled else { return }
        var chunks = buildChunks(for: meeting)
        guard !chunks.isEmpty else {
            MeetingMemoryStore.shared.remove(meetingID: meeting.id)
            meeting.memoryIndexedAt = nil
            try? appState.modelContext.save()
            return
        }
        do {
            let (client, _) = try appState.makeClient()
            let model = appState.settings.resolvedEmbeddingModelID
            let texts = chunks.map(\.text)
            let embeddings = try await client.embed(model: model, texts: texts)
            guard embeddings.count == chunks.count else { return }
            for index in chunks.indices {
                chunks[index].embedding = embeddings[index]
            }
            MeetingMemoryStore.shared.upsert(chunks: chunks)
            meeting.memoryIndexedAt = .now
            try? appState.modelContext.save()
        } catch {
            // Soft-fail: indexing is optional.
        }
    }

    @MainActor
    static func rebuildAll(appState: AppState) async {
        let meetings = MeetingStore.all(context: appState.modelContext)
            .filter {
                $0.status == .ready
                    || $0.summary != nil
                    || MeetingDocumentStore.hasDocuments(for: $0.id)
            }
        var allChunks: [MemoryChunk] = []
        guard appState.settings.memoryEnabled else {
            MeetingMemoryStore.shared.replaceAll([])
            return
        }
        do {
            let (client, _) = try appState.makeClient()
            let model = appState.settings.resolvedEmbeddingModelID
            for meeting in meetings {
                var chunks = buildChunks(for: meeting)
                guard !chunks.isEmpty else {
                    meeting.memoryIndexedAt = nil
                    continue
                }
                let embeddings = try await client.embed(model: model, texts: chunks.map(\.text))
                guard embeddings.count == chunks.count else { continue }
                for index in chunks.indices {
                    chunks[index].embedding = embeddings[index]
                }
                allChunks.append(contentsOf: chunks)
                meeting.memoryIndexedAt = .now
            }
            MeetingMemoryStore.shared.replaceAll(allChunks)
            try? appState.modelContext.save()
        } catch {
            // Soft-fail
        }
    }

    @MainActor
    private static func buildChunks(for meeting: Meeting) -> [MemoryChunk] {
        let summary = meeting.summary
        let segments = meeting.segments
            .sorted { $0.start < $1.start }
            .map { (start: $0.start, end: $0.end, text: "\(SpeakerProfileStore.shared.displayName(for: $0.speakerKey)): \($0.text)") }
        let documents = MeetingDocumentStore.extractableTexts(for: meeting.id)
        return MeetingChunker.chunks(
            meetingID: meeting.id,
            title: meeting.title,
            date: meeting.startedAt,
            transcriptSegments: segments,
            summary: summary,
            documents: documents
        )
    }
}
