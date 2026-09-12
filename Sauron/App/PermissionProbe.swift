import AVFoundation
import CoreGraphics
import Darwin
import EventKit
import Foundation
import Speech

enum PermissionProbe {
    static let argument = "--tcc-preflight"

    struct Snapshot: Codable, Equatable, Sendable {
        var screen: Bool
        /// Best-effort sync stand-in for App & Window Access (SCK probe + screen TCC).
        var windows: Bool
        var mic: Bool
        var speech: Bool
        var calendar: Bool

        static func current() -> Snapshot {
            let screen = CGPreflightScreenCaptureAccess()
            return Snapshot(
                screen: screen,
                windows: screen && UserDefaults.standard.bool(forKey: "didProbeWindowShareAccess"),
                mic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                speech: SFSpeechRecognizer.authorizationStatus() == .authorized,
                calendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess
            )
        }

        func hasNewlyGranted(comparedTo live: Snapshot) -> Bool {
            (screen && !live.screen)
                || (windows && !live.windows)
                || (mic && !live.mic)
                || (speech && !live.speech)
                || (calendar && !live.calendar)
        }
    }

    static func exitIfLaunchedAsProbe() {
        guard CommandLine.arguments.contains(argument) else { return }
        Darwin.exit(0)
    }
}

extension [PermissionStatus] {
    var allGranted: Bool {
        !isEmpty && allSatisfy(\.granted)
    }
}
