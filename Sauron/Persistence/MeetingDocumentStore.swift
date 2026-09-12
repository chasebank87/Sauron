import Foundation
import UniformTypeIdentifiers

struct MeetingDocument: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var originalName: String
    var storedName: String
    var contentType: String
    var byteCount: Int64
    var attachedAt: Date
}

enum MeetingDocumentStore {
    private static let manifestName = "documents.json"
    private static let folderName = "Documents"
    private static let lock = NSLock()

    static func documentsDirectory(for meetingID: UUID) -> URL {
        let url = MediaStore.folder(for: meetingID)
            .appending(path: folderName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func hasDocuments(for meetingID: UUID) -> Bool {
        !list(for: meetingID).isEmpty
    }

    static func list(for meetingID: UUID) -> [MeetingDocument] {
        lock.lock()
        defer { lock.unlock() }
        return loadManifestLocked(meetingID: meetingID)
            .sorted { $0.attachedAt > $1.attachedAt }
    }

    static func fileURL(for document: MeetingDocument, meetingID: UUID) -> URL {
        documentsDirectory(for: meetingID).appending(path: document.storedName)
    }

    @discardableResult
    static func attach(urls: [URL], to meetingID: UUID) throws -> [MeetingDocument] {
        guard !urls.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        let dir = documentsDirectory(for: meetingID)
        var manifest = loadManifestLocked(meetingID: meetingID)
        var attached: [MeetingDocument] = []
        let fm = FileManager.default

        for source in urls {
            let accessing = source.startAccessingSecurityScopedResource()
            defer {
                if accessing { source.stopAccessingSecurityScopedResource() }
            }

            let originalName = source.lastPathComponent
            let storedName = uniqueStoredName(originalName, existing: Set(manifest.map(\.storedName)))
            let destination = dir.appending(path: storedName)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let byteCount = Int64(values.fileSize ?? 0)
            let contentType = values.contentType?.identifier
                ?? UTType(filenameExtension: source.pathExtension)?.identifier
                ?? "public.data"
            let document = MeetingDocument(
                id: UUID(),
                originalName: originalName,
                storedName: storedName,
                contentType: contentType,
                byteCount: byteCount,
                attachedAt: .now
            )
            manifest.append(document)
            attached.append(document)
        }

        try saveManifestLocked(manifest, meetingID: meetingID)
        return attached
    }

    static func remove(id: UUID, from meetingID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        var manifest = loadManifestLocked(meetingID: meetingID)
        guard let index = manifest.firstIndex(where: { $0.id == id }) else { return }
        let document = manifest.remove(at: index)
        let url = documentsDirectory(for: meetingID).appending(path: document.storedName)
        try? FileManager.default.removeItem(at: url)
        try saveManifestLocked(manifest, meetingID: meetingID)
    }

    static func extractableTexts(for meetingID: UUID) -> [(name: String, text: String)] {
        list(for: meetingID).compactMap { document in
            let url = fileURL(for: document, meetingID: meetingID)
            guard let text = try? DocumentTextExtractor.extract(url: url) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (document.originalName, trimmed)
        }
    }

    // MARK: - Private

    private static func uniqueStoredName(_ original: String, existing: Set<String>) -> String {
        if !existing.contains(original) { return original }
        let ns = original as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    private static func manifestURL(meetingID: UUID) -> URL {
        documentsDirectory(for: meetingID).appending(path: manifestName)
    }

    private static func loadManifestLocked(meetingID: UUID) -> [MeetingDocument] {
        let url = manifestURL(meetingID: meetingID)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MeetingDocument].self, from: data)
        else { return [] }
        return decoded
    }

    private static func saveManifestLocked(_ documents: [MeetingDocument], meetingID: UUID) throws {
        let url = manifestURL(meetingID: meetingID)
        let data = try JSONEncoder().encode(documents)
        try data.write(to: url, options: [.atomic])
    }
}
