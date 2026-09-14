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
        return session.devices.map { device in
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

    /// Core Audio device ID whose UID matches an `AVCaptureDevice.uniqueID`.
    static func coreAudioDeviceID(matchingUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return allAudioDeviceIDs().first(where: { coreAudioUID(for: $0) == uid })
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func coreAudioUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard status == noErr else { return [] }
        return devices
    }
}
