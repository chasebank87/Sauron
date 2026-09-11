import AppKit
import CoreGraphics
import Foundation

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
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for item in urls {
            if let url = URL(string: item) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
