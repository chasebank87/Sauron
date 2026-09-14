import CoreGraphics
import Foundation

/// Scores and ranks meeting windows so we capture the call stage, not app chrome.
enum MeetingWindowPicker {
    /// Prefer real call/meeting stages over shell surfaces (Teams Calendar/Chat, etc.).
    static func score(_ candidate: MeetingCandidate) -> Int {
        let title = candidate.windowTitle
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var score = 0

        if title.range(of: #"meeting with"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 120
        }
        if title.range(of: #"call with"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 120
        }
        if title.range(of: #"\bmeeting\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 50
        }
        if title.range(of: #"\bcall\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 40
        }
        if title.range(of: #"\bhuddle\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 80
        }
        if title.range(of: #"\bwebinar\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 60
        }

        // FaceTime: prefer screen-share / named call windows over bare "FaceTime" chrome.
        if candidate.kind == .faceTime {
            if normalized.contains("screen") || normalized.contains("sharing") || normalized.contains("share") {
                score += 130
            }
            if !normalized.isEmpty, normalized != "facetime" {
                score += 45
            }
            if normalized == "facetime" {
                score -= 25
            }
            // Screen-share stages are usually the larger window.
            score += Int(min(candidate.pixelArea / 12_000, 90))
        } else {
            // Larger on-screen windows are more likely the active stage.
            score += Int(min(candidate.pixelArea / 20_000, 60))
        }

        // Mild penalty for generic leftovers.
        if normalized == "zoom" || normalized == "microsoft teams" {
            score -= 40
        }
        return score
    }

    static func best(from matches: [MeetingCandidate]) -> MeetingCandidate? {
        matches.max { score($0) < score($1) }
    }

    /// Best live window for the same meeting app as `seed` (used at record start).
    static func bestContinuing(from seed: MeetingCandidate, in matches: [MeetingCandidate]) -> MeetingCandidate? {
        let peers = matches.filter {
            $0.bundleIdentifier == seed.bundleIdentifier && $0.kind == seed.kind
        }
        return best(from: peers) ?? best(from: matches.filter { $0.kind == seed.kind })
    }
}
