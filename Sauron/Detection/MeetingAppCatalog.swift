import Foundation

enum MeetingAppCatalog {
    static let nativeBundleIDs: [String: MeetingKind] = [
        "us.zoom.xos": .zoom,
        "zoom.us": .zoom,
        "com.microsoft.teams2": .teams,
        "com.microsoft.teams": .teams,
        "com.microsoft.teams16": .teams,
        "com.apple.FaceTime": .faceTime,
        "com.apple.TelephonyUtilities": .faceTime,
        "Cisco-Systems.Spark": .webex,
        "com.cisco.webexmeetingsapp": .webex,
        "com.webex.meetingmanager": .webex,
        "com.cinchcast.webex": .webex,
        "com.tinyspeck.slackmacgap": .slack
    ]

    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "app.zen-browser.zen",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    private static let zoomExcludedTitles: Set<String> = [
        "zoom",
        "zoom workplace",
        "zoom cloud meetings",
        "settings",
        "login",
        "zoom - pro account",
        "zoom.us"
    ]

    /// Teams main-shell surfaces — these match `|` heuristics but are not the call window.
    private static let teamsShellHeads: Set<String> = [
        "calendar",
        "chat",
        "activity",
        "calls",
        "files",
        "apps",
        "settings",
        "teams",
        "microsoft teams",
        "onedrive",
        "communities",
        "multi-call window"
    ]

    static func match(
        bundleIdentifier: String?,
        appName: String?,
        windowTitle: String?
    ) -> MeetingKind? {
        let bundle = bundleIdentifier ?? ""
        let title = windowTitle ?? ""

        if bundle == "app.sauron.simulate" {
            return .simulated
        }

        if let kind = nativeBundleIDs[bundle] {
            return nativeMatch(kind: kind, title: title)
        }

        if browserBundleIDs.contains(bundle) {
            return webMatch(title: title)
        }

        // Some Electron shells report a generic bundle; still honor title heuristics.
        if let web = webMatch(title: title), (appName ?? "").localizedCaseInsensitiveContains("chrome") {
            return web
        }

        return nil
    }

    static func nativeMatch(kind: MeetingKind, title: String) -> MeetingKind? {
        let normalized = normalize(title)
        switch kind {
        case .zoom:
            if zoomExcludedTitles.contains(normalized) { return nil }
            return .zoom
        case .teams:
            return teamsMeetingMatch(title: title, normalized: normalized)
        case .faceTime:
            return .faceTime
        case .webex:
            if titleMatches(title, patterns: [#"webex"#, #"\bmeeting\b"#, #"\bcall\b"#]) {
                return .webex
            }
            return normalized.isEmpty ? nil : .webex
        case .slack:
            if titleMatches(title, patterns: [#"huddle"#]) {
                return .slack
            }
            return nil
        default:
            return kind
        }
    }

    /// Prefer call/meeting stages; never treat Calendar/Chat shells as meetings.
    static func teamsMeetingMatch(title: String, normalized: String) -> MeetingKind? {
        if normalized.isEmpty { return nil }
        if isTeamsShellTitle(normalized) { return nil }

        // Strong meeting signals.
        if titleMatches(
            title,
            patterns: [
                #"meeting with"#,
                #"call with"#,
                #"\bmeeting\b"#,
                #"\bcall\b"#,
                #"\bwebinar\b"#
            ]
        ) {
            return .teams
        }

        // "Design review | Microsoft Teams" style — allow non-shell heads.
        if titleMatches(title, patterns: [#"\|\s*microsoft teams\s*$"#]) {
            return .teams
        }

        return nil
    }

    static func isTeamsShellTitle(_ normalizedTitle: String) -> Bool {
        let head = normalizedTitle
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { normalize(String($0)) } ?? normalizedTitle

        if teamsShellHeads.contains(head) { return true }
        // "Calendar | (External) | Microsoft Teams"
        if head.hasPrefix("calendar") { return true }
        if head.hasPrefix("chat") { return true }
        if head.hasPrefix("activity") { return true }
        if head.hasPrefix("calls") { return true }
        return false
    }

    static func webMatch(title: String) -> MeetingKind? {
        if titleMatches(
            title,
            patterns: [
                #"google meet"#,
                #"meet\.google\.com"#,
                #"\bmeet [-–—]"#,
                #"[-–—] meet\b"#
            ]
        ) {
            return .meet
        }
        if titleMatches(
            title,
            patterns: [#"zoom meeting"#, #"zoom webinar"#, #"zoom\.us/.+/j/"#]
        ) {
            return .zoom
        }
        if titleMatches(
            title,
            patterns: [#"microsoft teams"#, #"teams\.microsoft\.com"#, #"teams\.live\.com"#]
        ), titleMatches(title, patterns: [#"\bmeeting\b"#, #"\bcall\b"#, #"\|"#]) {
            // Browser Teams tabs still use shell names sometimes.
            if isTeamsShellTitle(normalize(title)) { return nil }
            return .teams
        }
        if titleMatches(title, patterns: [#"webex"#]) {
            return .webex
        }
        return nil
    }

    static func titleMatches(_ title: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
