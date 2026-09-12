import Foundation

enum MediaStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _customMeetingsRoot: URL?
    private static let legacyApplicationSupportName = "Observer"
    private static let applicationSupportName = "Sauron"
    nonisolated(unsafe) private static var didMigrate = false

    static var customMeetingsRoot: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _customMeetingsRoot
        }
        set {
            lock.lock()
            _customMeetingsRoot = newValue
            lock.unlock()
        }
    }

    static var applicationSupport: URL {
        migrateFromObserverIfNeeded()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: applicationSupportName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var defaultMeetingsRoot: URL {
        let url = applicationSupport.appending(path: "Meetings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var meetingsRoot: URL {
        if let custom = customMeetingsRoot {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        return defaultMeetingsRoot
    }

    static func folder(for id: UUID) -> URL {
        let url = meetingsRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func applyCustomRoot(path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customMeetingsRoot = nil
        } else {
            customMeetingsRoot = URL(fileURLWithPath: trimmed, isDirectory: true)
        }
    }

    /// One-time move of Application Support/Observer → Sauron when Sauron is empty.
    static func migrateFromObserverIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didMigrate else { return }
        didMigrate = true

        let fm = FileManager.default
        let supportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = supportRoot.appending(path: legacyApplicationSupportName, directoryHint: .isDirectory)
        let modern = supportRoot.appending(path: applicationSupportName, directoryHint: .isDirectory)

        guard fm.fileExists(atPath: legacy.path) else { return }

        let modernExists = fm.fileExists(atPath: modern.path)
        let modernIsEmpty: Bool = {
            guard modernExists,
                  let items = try? fm.contentsOfDirectory(atPath: modern.path)
            else { return !modernExists }
            return items.isEmpty
        }()

        if !modernExists || modernIsEmpty {
            try? fm.createDirectory(at: modern.deletingLastPathComponent(), withIntermediateDirectories: true)
            if modernExists {
                try? fm.removeItem(at: modern)
            }
            try? fm.moveItem(at: legacy, to: modern)
        }
    }
}
