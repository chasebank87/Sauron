import Foundation

struct MemoryHit: Equatable, Sendable, Identifiable {
    var id: UUID { chunk.id }
    var chunk: MemoryChunk
    var score: Float
}

struct MemoryCitation: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var meetingID: UUID
    var meetingTitle: String
    var text: String
    var score: Float

    init(hit: MemoryHit) {
        id = hit.chunk.id
        meetingID = hit.chunk.meetingID
        meetingTitle = hit.chunk.meetingTitle
        text = hit.chunk.text
        score = hit.score
    }

    init(id: UUID = UUID(), meetingID: UUID, meetingTitle: String, text: String, score: Float) {
        self.id = id
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.text = text
        self.score = score
    }
}

/// On-disk vector index for past meetings. Embeddings computed via LLMClient.
final class MeetingMemoryStore: @unchecked Sendable {
    static let shared = MeetingMemoryStore()

    private let lock = NSLock()
    private var chunks: [MemoryChunk] = []
    private var lastRebuildAt: Date?
    private let fileURL: URL

    var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }

    var lastRebuild: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastRebuildAt
    }

    private init() {
        let dir = MediaStore.applicationSupport.appending(path: "Memory", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "MemoryIndex.json")
        load()
    }

    func upsert(chunks newChunks: [MemoryChunk]) {
        guard !newChunks.isEmpty else { return }
        let meetingIDs = Set(newChunks.map(\.meetingID))
        lock.lock()
        chunks.removeAll { meetingIDs.contains($0.meetingID) }
        chunks.append(contentsOf: newChunks)
        lastRebuildAt = .now
        persistLocked()
        lock.unlock()
    }

    func remove(meetingID: UUID) {
        lock.lock()
        chunks.removeAll { $0.meetingID == meetingID }
        persistLocked()
        lock.unlock()
    }

    func search(queryEmbedding: [Float], limit: Int, floor: Float = 0.35) -> [MemoryHit] {
        lock.lock()
        let snapshot = chunks
        lock.unlock()
        guard !queryEmbedding.isEmpty else { return [] }
        var hits: [MemoryHit] = []
        hits.reserveCapacity(min(limit * 2, snapshot.count))
        for chunk in snapshot {
            guard !chunk.embedding.isEmpty else { continue }
            let score = Self.cosine(queryEmbedding, chunk.embedding)
            if score >= floor {
                hits.append(MemoryHit(chunk: chunk, score: score))
            }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    func replaceAll(_ newChunks: [MemoryChunk]) {
        lock.lock()
        chunks = newChunks
        lastRebuildAt = .now
        persistLocked()
        lock.unlock()
    }

    func meetingIDs() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(chunks.map(\.meetingID))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    static func formatContext(_ hits: [MemoryHit]) -> String {
        guard !hits.isEmpty else { return "" }
        return hits.enumerated().map { index, hit in
            let title = hit.chunk.meetingTitle
            let date = hit.chunk.meetingDate.formatted(date: .abbreviated, time: .omitted)
            return "[\(index + 1)] \(title) (\(date))\n\(hit.chunk.text)"
        }.joined(separator: "\n\n")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(IndexFile.self, from: data)
        else { return }
        chunks = decoded.chunks
        lastRebuildAt = decoded.updatedAt
    }

    private func persistLocked() {
        let file = IndexFile(updatedAt: lastRebuildAt ?? .now, chunks: chunks)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private struct IndexFile: Codable {
        var updatedAt: Date
        var chunks: [MemoryChunk]
    }
}
