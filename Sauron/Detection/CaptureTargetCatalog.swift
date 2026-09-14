import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Builds the prompt’s capture-target menu: auto, meeting windows, other windows, displays.
enum CaptureTargetCatalog {
    static func options(for candidate: MeetingCandidate?) async -> [CaptureTargetOption] {
        var options: [CaptureTargetOption] = [
            CaptureTargetOption(
                id: CaptureVideoTarget.auto.id,
                title: "Auto (recommended)",
                subtitle: autoSubtitle(for: candidate),
                systemImage: "sparkles.rectangle.stack",
                target: .auto
            )
        ]

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return options + displayOptions(from: nil)
        }

        let meetingWindows = content.windows
            .compactMap { window -> (SCWindow, MeetingCandidate)? in
                guard let match = meetingMatch(window: window, seed: candidate) else { return nil }
                return (window, match)
            }
            .sorted { MeetingWindowPicker.score($0.1) > MeetingWindowPicker.score($1.1) }

        for (window, match) in meetingWindows {
            let title = windowLabel(window, fallback: match.displayName)
            options.append(
                CaptureTargetOption(
                    id: CaptureVideoTarget.window(window.windowID).id,
                    title: title,
                    subtitle: match.appName,
                    systemImage: match.kind.systemImage,
                    target: .window(window.windowID)
                )
            )
        }

        // Other on-screen windows (custom pick) — skip tiny chrome and already-listed IDs.
        let listed = Set(meetingWindows.map(\.0.windowID))
        let others = content.windows
            .filter { window in
                guard window.isOnScreen, !listed.contains(window.windowID) else { return false }
                let frame = window.frame
                guard frame.width >= 280, frame.height >= 180 else { return false }
                // Skip our own UI.
                if window.owningApplication?.bundleIdentifier == "app.sauron.Sauron" { return false }
                return true
            }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .prefix(12)

        for window in others {
            let app = window.owningApplication?.applicationName ?? "App"
            options.append(
                CaptureTargetOption(
                    id: CaptureVideoTarget.window(window.windowID).id,
                    title: windowLabel(window, fallback: app),
                    subtitle: "Other window · \(app)",
                    systemImage: "macwindow",
                    target: .window(window.windowID)
                )
            )
        }

        options.append(contentsOf: displayOptions(from: content))
        return options
    }

    private static func autoSubtitle(for candidate: MeetingCandidate?) -> String {
        guard let candidate else {
            return "Best meeting window at start"
        }
        if candidate.kind == .faceTime {
            return "Picks the FaceTime call or screen-share window"
        }
        return "Best \(candidate.kind.displayName) window at start"
    }

    private static func meetingMatch(window: SCWindow, seed: MeetingCandidate?) -> MeetingCandidate? {
        guard window.isOnScreen else { return nil }
        let frame = window.frame
        guard frame.width >= 220, frame.height >= 160 else { return nil }
        let title = window.title ?? ""
        let bundle = window.owningApplication?.bundleIdentifier
        let appName = window.owningApplication?.applicationName
        guard let kind = MeetingAppCatalog.match(
            bundleIdentifier: bundle,
            appName: appName,
            windowTitle: title
        ) else { return nil }

        // Prefer same meeting as the prompt when known.
        if let seed, kind != seed.kind, seed.kind != .simulated, seed.kind != .unknown {
            // Still allow sibling FaceTime/TelephonyUtilities windows.
            let sameFamily = seed.kind == .faceTime && kind == .faceTime
            if !sameFamily { return nil }
        }

        return MeetingCandidate(
            id: "\(bundle ?? "unknown"):\(window.windowID)",
            kind: kind,
            appName: appName ?? kind.displayName,
            bundleIdentifier: bundle ?? "unknown",
            windowTitle: title,
            windowID: window.windowID,
            isSimulated: false,
            calendarEventTitle: nil,
            pixelArea: max(frame.width, 1) * max(frame.height, 1)
        )
    }

    private static func displayOptions(from content: SCShareableContent?) -> [CaptureTargetOption] {
        let displays = content?.displays ?? []
        if displays.isEmpty {
            let main = CGMainDisplayID()
            return [
                CaptureTargetOption(
                    id: CaptureVideoTarget.display(main).id,
                    title: "Entire screen",
                    subtitle: "Main display",
                    systemImage: "display",
                    target: .display(main)
                )
            ]
        }
        return displays.enumerated().map { index, display in
            let isMain = display.displayID == CGMainDisplayID()
            let name = isMain ? "Main display" : "Display \(index + 1)"
            return CaptureTargetOption(
                id: CaptureVideoTarget.display(display.displayID).id,
                title: "Entire screen",
                subtitle: "\(name) · \(display.width)×\(display.height)",
                systemImage: "display",
                target: .display(display.displayID)
            )
        }
    }

    private static func windowLabel(_ window: SCWindow, fallback: String) -> String {
        let title = (window.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return fallback }
        return title
    }
}
