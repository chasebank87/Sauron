import Foundation
import SwiftData

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

    /// Re-links a meeting's media paths to raw capture files that exist on disk under its
    /// conventional filenames (video.mp4/mic.m4a/system.m4a) but aren't referenced by the
    /// model -- covers a finished recording whose paths never made it into the saved
    /// meeting (e.g. capture succeeded but the model write after it didn't land). Only
    /// fills in paths that are currently empty; never overwrites an existing path.
    @MainActor
    @discardableResult
    static func repairMediaLinks(context: ModelContext) -> Int {
        var repaired = 0
        for meeting in MeetingStore.all(context: context) {
            let folder = folder(for: meeting.id)
            var changed = false
            if (meeting.videoPath ?? "").isEmpty {
                let url = folder.appending(path: "video.mp4")
                if isNonEmptyFile(url) {
                    meeting.videoPath = url.path
                    changed = true
                }
            }
            if (meeting.micAudioPath ?? "").isEmpty {
                let url = folder.appending(path: "mic.m4a")
                if isNonEmptyFile(url) {
                    meeting.micAudioPath = url.path
                    changed = true
                }
            }
            if (meeting.systemAudioPath ?? "").isEmpty {
                let url = folder.appending(path: "system.m4a")
                if isNonEmptyFile(url) {
                    meeting.systemAudioPath = url.path
                    changed = true
                }
            }
            if changed { repaired += 1 }
        }
        if repaired > 0 {
            try? context.save()
        }
        return repaired
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            return false
        }
        return size > 0
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
