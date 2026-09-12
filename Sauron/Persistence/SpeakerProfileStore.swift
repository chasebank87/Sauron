import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class SpeakerProfileStore {
    static let shared = SpeakerProfileStore()

    private(set) var profiles: [SpeakerProfile] = []
    private var context: ModelContext?

    private init() {}

    func attach(context: ModelContext) {
        self.context = context
        ensureSelfProfile()
        reload()
    }

    func reload() {
        guard let context else {
            profiles = []
            return
        }
        var descriptor = FetchDescriptor<SpeakerProfile>(
            sortBy: [
                SortDescriptor(\.sortIndex),
                SortDescriptor(\.name)
            ]
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        profiles = fetched.sorted { lhs, rhs in
            if lhs.isSelf != rhs.isSelf { return lhs.isSelf && !rhs.isSelf }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    func ensureSelfProfile() -> SpeakerProfile {
        guard let context else {
            fatalError("SpeakerProfileStore must attach a ModelContext before use.")
        }
        if let existing = profiles.first(where: \.isSelf)
            ?? ((try? context.fetch(FetchDescriptor<SpeakerProfile>())) ?? []).first(where: \.isSelf) {
            return existing
        }
        let selfProfile = SpeakerProfile(name: "You", isSelf: true, sortIndex: 0)
        context.insert(selfProfile)
        try? context.save()
        reload()
        return selfProfile
    }

    var selfProfile: SpeakerProfile {
        ensureSelfProfile()
    }

    var otherProfiles: [SpeakerProfile] {
        profiles.filter { !$0.isSelf }
    }

    func displayName(for speakerKey: String) -> String {
        let key = SpeakerKey.normalize(speakerKey)
        if SpeakerKey.isSelf(key) {
            return selfProfile.name.isEmpty ? "You" : selfProfile.name
        }
        if let id = SpeakerKey.profileID(key),
           let profile = profiles.first(where: { $0.id == id }) {
            return profile.name
        }
        return SpeakerKey.fallbackDisplayName(key)
    }

    func renameSelf(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ensureSelfProfile()
        profile.name = trimmed.isEmpty ? "You" : trimmed
        save()
    }

    @discardableResult
    func addPerson(name: String) -> SpeakerProfile {
        guard let context else {
            fatalError("SpeakerProfileStore must attach a ModelContext before use.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextIndex = (otherProfiles.map(\.sortIndex).max() ?? 0) + 1
        let profile = SpeakerProfile(
            name: trimmed.isEmpty ? "Person \(nextIndex)" : trimmed,
            isSelf: false,
            sortIndex: nextIndex
        )
        context.insert(profile)
        save()
        return profile
    }

    func rename(_ profile: SpeakerProfile, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profile.name = trimmed
        save()
    }

    func delete(_ profile: SpeakerProfile) {
        guard let context, !profile.isSelf else { return }
        context.delete(profile)
        save()
    }

    func moveOther(from source: IndexSet, to destination: Int) {
        var others = otherProfiles
        others.move(fromOffsets: source, toOffset: destination)
        for (index, profile) in others.enumerated() {
            profile.sortIndex = index + 1
        }
        save()
    }

    func updateVoiceprint(_ profile: SpeakerProfile, vector: [Float]) {
        guard !vector.isEmpty else { return }
        let existing = profile.voiceprint
        if existing.isEmpty {
            profile.voiceprint = vector
        } else if existing.count == vector.count {
            profile.voiceprint = zip(existing, vector).map { ($0 + $1) * 0.5 }
        } else {
            profile.voiceprint = vector
        }
        save()
    }

    func voiceprints() -> [(key: String, vector: [Float])] {
        profiles.compactMap { profile in
            let vector = profile.voiceprint
            guard !vector.isEmpty else { return nil }
            return (profile.speakerKey, vector)
        }
    }

    private func save() {
        try? context?.save()
        reload()
    }
}
