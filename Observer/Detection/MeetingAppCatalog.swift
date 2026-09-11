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

    static func match(
        bundleIdentifier: String?,
        appName: String?,
        windowTitle: String?
    ) -> MeetingKind? {
        let bundle = bundleIdentifier ?? ""
        let title = windowTitle ?? ""

        if bundle == "app.observer.simulate" {
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
            if normalized.isEmpty { return nil }
            if titleMatches(
                title,
                patterns: [#"\bmeeting\b"#, #"\bcall\b"#, #"\|"#, #"microsoft teams"#]
            ) {
                return .teams
            }
            return nil
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

    private static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
