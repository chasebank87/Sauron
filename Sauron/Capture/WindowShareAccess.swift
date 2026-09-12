import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Probes ScreenCaptureKit window/app capture (`SCContentFilter` + `SCStream`),
/// which on macOS 26 can prompt separately from `CGRequestScreenCaptureAccess`.
@MainActor
enum WindowShareAccess {
    private static let probedKey = "didProbeWindowShareAccess"
    private static let streamDelegate = StreamProbeDelegate()
    private static var cachedGranted: Bool?
    private static var cachedAt: Date?
    private static let cacheTTL: TimeInterval = 2

    static var wasProbed: Bool {
        UserDefaults.standard.bool(forKey: probedKey)
    }

    /// Safe for polling. Does not start a stream. Avoids calling into SCK when
    /// Screen Recording preflight is false (that call can itself prompt).
    static func granted() async -> Bool {
        guard ScreenCaptureAccess.granted() else {
            cachedGranted = false
            cachedAt = Date()
            return false
        }
        guard wasProbed else {
            cachedGranted = false
            cachedAt = Date()
            return false
        }
        if let cachedGranted, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheTTL {
            return cachedGranted
        }
        let value = await canEnumerateShareableContent()
        self.cachedGranted = value
        self.cachedAt = Date()
        return value
    }

    /// Mirrors the recording path: enumerate shareable content, build a
    /// window/app `SCContentFilter`, briefly start/stop an `SCStream` so the
    /// system window-sharing consent surfaces during onboarding.
    static func request() async {
        UserDefaults.standard.set(true, forKey: probedKey)
        UserDefaults.standard.synchronize()
        cachedGranted = nil
        cachedAt = nil

        if !ScreenCaptureAccess.granted() {
            ScreenCaptureAccess.request()
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let filter = try makeFilter(content: content)
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.queueDepth = 1

            let stream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)
            try await stream.startCapture()
            try await stream.stopCapture()
            cachedGranted = true
            cachedAt = Date()
        } catch {
            cachedGranted = false
            cachedAt = Date()
            if !ScreenCaptureAccess.granted() {
                ScreenCaptureAccess.request()
            }
        }
    }

    private static func canEnumerateShareableContent() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return content.displays.first != nil
                && (!content.windows.isEmpty || !content.applications.isEmpty)
        } catch {
            return false
        }
    }

    private static func makeFilter(content: SCShareableContent) throws -> SCContentFilter {
        let ownBundle = Bundle.main.bundleIdentifier
        if let ownWindow = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == ownBundle
        }) {
            return SCContentFilter(desktopIndependentWindow: ownWindow)
        }
        if let window = content.windows.first(where: \.isOnScreen) ?? content.windows.first {
            return SCContentFilter(desktopIndependentWindow: window)
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
        else {
            throw SauronError.noDisplay
        }
        if let app = content.applications.first(where: { $0.bundleIdentifier == ownBundle })
            ?? content.applications.first
        {
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }
}

private final class StreamProbeDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {}
