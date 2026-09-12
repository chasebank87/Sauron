import Foundation

enum MediaStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _customMeetingsRoot: URL?

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
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Observer", directoryHint: .isDirectory)
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
}
