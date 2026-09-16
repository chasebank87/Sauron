import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Hashable, Sendable {
    /// Sentinel for “System Default Input” — always priority #1.
    static let systemDefaultID = "__system_default__"

    var id: String
    var name: String
    var isSystemDefault: Bool

    static var systemDefault: AudioInputDevice {
        let defaultName = AVCaptureDevice.default(for: .audio)?.localizedName
        let suffix = defaultName.map { " (\($0))" } ?? ""
        return AudioInputDevice(
            id: systemDefaultID,
            name: "System Default\(suffix)",
            isSystemDefault: true
        )
    }

    /// Concrete capture device ID for ScreenCaptureKit, or nil to use the system default.
    var captureDeviceID: String? {
        isSystemDefault ? nil : id
    }
}

enum AudioDeviceCatalog {
    static func physicalInputs() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices
            .map { device in
                AudioInputDevice(id: device.uniqueID, name: device.localizedName, isSystemDefault: false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Priority list for UI and capture: System Default first, then saved order, then any new devices.
    static func resolvedPriority(savedIDs: [String]) -> [AudioInputDevice] {
        let physical = physicalInputs()
        let byID = Dictionary(uniqueKeysWithValues: physical.map { ($0.id, $0) })
        var result: [AudioInputDevice] = [.systemDefault]
        var seen: Set<String> = [AudioInputDevice.systemDefaultID]

        for id in savedIDs where id != AudioInputDevice.systemDefaultID {
            guard let device = byID[id], !seen.contains(id) else { continue }
            result.append(device)
            seen.insert(id)
        }
        for device in physical where !seen.contains(device.id) {
            result.append(device)
            seen.insert(device.id)
        }
        return result
    }

    static func device(id: String, savedIDs: [String]) -> AudioInputDevice? {
        resolvedPriority(savedIDs: savedIDs).first(where: { $0.id == id })
    }

    /// Whether a concrete capture device ID is still plugged in (System Default always counts as present).
    static func isAvailable(id: String) -> Bool {
        if id == AudioInputDevice.systemDefaultID { return true }
        return physicalInputs().contains(where: { $0.id == id })
    }
}
