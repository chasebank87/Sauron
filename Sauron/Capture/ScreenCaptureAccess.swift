import AppKit
import CoreGraphics
import Foundation

@MainActor
enum ScreenCaptureAccess {
    private static let requestedKey = "didRequestScreenCapture"

    static var wasRequested: Bool {
        UserDefaults.standard.bool(forKey: requestedKey)
    }

    /// Never prompts. Safe to call from polling.
    static func granted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func request() {
        UserDefaults.standard.set(true, forKey: requestedKey)
        UserDefaults.standard.synchronize()
        if CGPreflightScreenCaptureAccess() {
            return
        }
        if CGRequestScreenCaptureAccess() {
            return
        }
        openScreenPrivacy()
    }

    private static func openScreenPrivacy() {
        PermissionService.demoteFloatingPanelsForSystemUI()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for item in urls {
            if let url = URL(string: item) {
                NSWorkspace.shared.open(url)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    PermissionService.demoteFloatingPanelsForSystemUI()
                    if let settings = NSWorkspace.shared.runningApplications.first(where: {
                        let id = $0.bundleIdentifier ?? ""
                        return id.contains("SystemSettings")
                            || id.contains("systempreferences")
                            || id.contains("Preference")
                    }) {
                        settings.activate(options: [.activateIgnoringOtherApps])
                    }
                }
                return
            }
        }
    }
}
