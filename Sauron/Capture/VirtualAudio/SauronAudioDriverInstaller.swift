import AppKit
import Foundation

/// Copies `SauronAudio.driver` into `/Library/Audio/Plug-Ins/HAL` and restarts `coreaudiod`.
enum SauronAudioDriverInstaller {
    enum InstallError: LocalizedError {
        case bundledDriverMissing
        case privilegeFailed(String)
        case deviceDidNotAppear

        var errorDescription: String? {
            switch self {
            case .bundledDriverMissing:
                return "Sauron Audio driver is missing from the app bundle. Rebuild with scripts/build-sauron-audio-driver.sh."
            case .privilegeFailed(let detail):
                return "Could not install Sauron Audio (admin required): \(detail)"
            case .deviceDidNotAppear:
                return "Driver installed but Sauron Audio did not appear. Try logging out or restarting, then reopen Sauron."
            }
        }
    }

    /// Install (or reinstall) the HAL plug-in. Prompts for an admin password via osascript.
    static func install() async throws {
        guard let source = VirtualAudioDevice.bundledDriverURL,
              FileManager.default.fileExists(atPath: source.path)
        else {
            throw InstallError.bundledDriverMissing
        }

        let destination = VirtualAudioDevice.installedBundlePath
        let script = """
        set src to POSIX file "\(escapeAppleScript(source.path))"
        do shell script "rm -rf \(shellQuote(destination)) && mkdir -p \(shellQuote(VirtualAudioDevice.installDirectory)) && cp -R \(shellQuote(source.path)) \(shellQuote(destination)) && chown -R root:wheel \(shellQuote(destination)) && chmod -R 755 \(shellQuote(destination)) && /usr/bin/killall coreaudiod" with administrator privileges
        """

        try await runAppleScript(script)

        let appeared = await waitForDevice(timeoutSeconds: 12)
        guard appeared else { throw InstallError.deviceDidNotAppear }
    }

    /// Restart Core Audio so an already-copied driver is rescanned (admin prompt).
    static func reloadCoreAudio() async throws {
        let script = """
        do shell script "/usr/bin/killall coreaudiod" with administrator privileges
        """
        try await runAppleScript(script)
        let appeared = await waitForDevice(timeoutSeconds: 12)
        guard appeared || VirtualAudioDevice.isBundleInstalledOnDisk else {
            throw InstallError.deviceDidNotAppear
        }
    }

    private static func waitForDevice(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if VirtualAudioDevice.isLoaded() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return VirtualAudioDevice.isLoaded()
    }

    private static func runAppleScript(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let message = (error[NSAppleScript.errorMessage] as? String)
                        ?? error.description
                    continuation.resume(throwing: InstallError.privilegeFailed(message))
                    return
                }
                _ = result
                continuation.resume()
            }
        }
    }

    private static func escapeAppleScript(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
