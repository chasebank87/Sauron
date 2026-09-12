import Foundation

/// Local chat threads for Dashboard Chat (JSON on disk).
struct DashboardChatMessage: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var role: String
    var content: String
    var citations: [MemoryCitation]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        citations: [MemoryCitation] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.createdAt = createdAt
    }
}

struct DashboardChatThread: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [DashboardChatMessage]

    init(id: UUID = UUID(), title: String = "New chat", messages: [DashboardChatMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.messages = messages
    }
}

final class DashboardChatStore: @unchecked Sendable {
    static let shared = DashboardChatStore()

    private let lock = NSLock()
    private var threads: [DashboardChatThread] = []
    private let fileURL: URL

    private init() {
        let dir = MediaStore.applicationSupport.appending(path: "Chat", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "threads.json")
        load()
    }

    func allThreads() -> [DashboardChatThread] {
        lock.lock()
        defer { lock.unlock() }
        return threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ thread: DashboardChatThread) {
        lock.lock()
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.insert(thread, at: 0)
        }
        persistLocked()
        lock.unlock()
    }

    func delete(id: UUID) {
        lock.lock()
        threads.removeAll { $0.id == id }
        persistLocked()
        lock.unlock()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        threads.removeAll { ids.contains($0.id) }
        persistLocked()
        lock.unlock()
    }

    func rename(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        if let index = threads.firstIndex(where: { $0.id == id }) {
            threads[index].title = trimmed
            threads[index].updatedAt = .now
            persistLocked()
        }
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        threads = []
        persistLocked()
        lock.unlock()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DashboardChatThread].self, from: data)
        else { return }
        threads = decoded
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(threads) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
