import CoreAudio
import Foundation

/// Identifiers for the Sauron Audio HAL plug-in (virtual loopback device).
enum VirtualAudioDevice {
    static let displayName = "Sauron Audio"
    static let deviceUID = "app.sauron.audio.SauronAudio"
    static let bundleIdentifier = "app.sauron.audio.driver"
    static let installDirectory = "/Library/Audio/Plug-Ins/HAL"
    static let installedBundleName = "SauronAudio.driver"
    static var installedBundlePath: String { "\(installDirectory)/\(installedBundleName)" }

    /// Bundled driver inside the app (built by `scripts/build-sauron-audio-driver.sh`).
    static var bundledDriverURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("Drivers", isDirectory: true)
            .appendingPathComponent(installedBundleName, isDirectory: true)
    }

    static var isBundleInstalledOnDisk: Bool {
        FileManager.default.fileExists(atPath: installedBundlePath)
    }

    /// True when Core Audio has enumerated the virtual device (driver loaded).
    static func isLoaded() -> Bool {
        coreAudioDeviceID() != nil
    }

    static func coreAudioDeviceID() -> AudioDeviceID? {
        AudioDeviceCatalog.coreAudioDeviceID(matchingUID: deviceUID)
    }

    enum Status: Equatable, Sendable {
        case missing
        case installedButNotLoaded
        case loaded

        var label: String {
            switch self {
            case .missing: "Not installed"
            case .installedButNotLoaded: "Installed — reload Core Audio"
            case .loaded: "Ready"
            }
        }
    }

    static func status() -> Status {
        if isLoaded() { return .loaded }
        if isBundleInstalledOnDisk { return .installedButNotLoaded }
        return .missing
    }
}
