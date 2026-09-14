import Foundation

/// Policy for hiding the transcript + Live Assist panes while the user presents.
enum LivePaneSharePolicy {
    static func shouldHidePanes(
        settingEnabled: Bool,
        isUserScreenSharing: Bool,
        isRecording: Bool
    ) -> Bool {
        settingEnabled && isUserScreenSharing && isRecording
    }
}

/// Sticky true while a local screen-share is detected; drops after a short gap so
/// a single missed window poll does not flash the HUD back onto a live share.
struct ScreenShareHold: Equatable, Sendable {
    var isSharing = false
    var missingSince: Date?

    /// How long share chrome may disappear before we treat the share as ended.
    static let endGrace: TimeInterval = 0.9

    mutating func update(detected: Bool, now: Date = Date(), endGrace: TimeInterval = Self.endGrace) {
        if detected {
            missingSince = nil
            isSharing = true
            return
        }
        guard isSharing else {
            missingSince = nil
            return
        }
        let started = missingSince ?? now
        missingSince = started
        if now.timeIntervalSince(started) >= endGrace {
            isSharing = false
            missingSince = nil
        }
    }
}

/// Detects that *this Mac* is presenting into Zoom, Meet, Teams, FaceTime, Webex, or Slack.
///
/// Sauron’s own ScreenCaptureKit recording must not count — only meeting-app share
/// chrome, presenter tab titles, and known share helper processes.
enum LocalScreenShareSignal {
    struct WindowProbe: Equatable, Sendable {
        var title: String
        var bundleIdentifier: String?
        var appName: String?
    }

    static func indicatesLocalShare(
        windowTitle: String,
        bundleIdentifier: String? = nil,
        appName: String? = nil
    ) -> Bool {
        if isShareHelper(bundleIdentifier: bundleIdentifier, appName: appName) {
            return true
        }

        let normalized = MeetingAppCatalog.normalize(windowTitle)
        guard !normalized.isEmpty else { return false }

        if hasStrongPresenterTitle(normalized) {
            return true
        }

        if isMeetingNative(bundleIdentifier: bundleIdentifier, appName: appName),
           hasMeetingAppShareTitle(normalized) {
            return true
        }

        if isBrowser(bundleIdentifier: bundleIdentifier),
           hasBrowserPresenterTitle(normalized) {
            return true
        }

        return false
    }

    static func isShareDetected(
        windows: [WindowProbe],
        runningApps: [(bundleIdentifier: String?, appName: String?)] = []
    ) -> Bool {
        if runningApps.contains(where: { isShareHelper(bundleIdentifier: $0.bundleIdentifier, appName: $0.appName) }) {
            return true
        }
        return windows.contains {
            indicatesLocalShare(
                windowTitle: $0.title,
                bundleIdentifier: $0.bundleIdentifier,
                appName: $0.appName
            )
        }
    }

    static func isShareHelper(bundleIdentifier: String?, appName: String?) -> Bool {
        let bundle = (bundleIdentifier ?? "").lowercased()
        let app = MeetingAppCatalog.normalize(appName ?? "")
        if bundle.contains("cpthost") || bundle.contains("zoomcpt") {
            return true
        }
        if app == "cpthost" || app.contains("zoom sharing") {
            return true
        }
        return false
    }

    static func hasStrongPresenterTitle(_ normalizedTitle: String) -> Bool {
        MeetingAppCatalog.titleMatches(
            normalizedTitle,
            patterns: [
                #"you(?:['’]re| are) (?:screen )?sharing(?: your| the)? (?:screen|window|desktop)"#,
                #"you(?:['’]re| are) presenting"#,
                #"presenting now"#,
                #"presenting to everyone"#,
                #"sharing your (?:screen|window|desktop)"#,
                #"sharing the (?:screen|window|desktop)"#,
                #"sharing an? (?:application|window|screen)"#,
                #"you(?:['’]re| are) screen sharing"#
            ]
        )
    }

    static func hasMeetingAppShareTitle(_ normalizedTitle: String) -> Bool {
        if normalizedTitle == "sharing" || normalizedTitle == "presenting" {
            return true
        }
        return MeetingAppCatalog.titleMatches(
            normalizedTitle,
            patterns: [
                #"sharing (?:toolbar|control|bar|preview|status)"#,
                #"screen sharing(?: toolbar)?"#,
                #"stop sharing"#,
                #"pause share"#,
                #"you(?:['’]re| are) sharing"#
            ]
        )
    }

    /// Weak presenter chrome in a browser tab still has to look like a meeting tab.
    /// First-person titles are handled by `hasStrongPresenterTitle` for any owner.
    static func hasBrowserPresenterTitle(_ normalizedTitle: String) -> Bool {
        guard MeetingAppCatalog.titleMatches(
            normalizedTitle,
            patterns: [
                #"\bpresenting\b"#,
                #"\bscreen sharing\b"#,
                #"stop sharing"#
            ]
        ) else {
            return false
        }
        return MeetingAppCatalog.webMatch(normalizedTitle) != nil
    }

    static func isMeetingNative(bundleIdentifier: String?, appName: String?) -> Bool {
        let bundle = bundleIdentifier ?? ""
        if MeetingAppCatalog.nativeBundleIDs[bundle] != nil {
            return true
        }
        let app = MeetingAppCatalog.normalize(appName ?? "")
        if app.contains("zoom") || app.contains("microsoft teams") || app.contains("webex")
            || app.contains("facetime") || app == "slack" {
            return true
        }
        return false
    }

    static func isBrowser(bundleIdentifier: String?) -> Bool {
        MeetingAppCatalog.browserBundleIDs.contains(bundleIdentifier ?? "")
    }
}
